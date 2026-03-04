#import "OpenCVSegmentationBridge.h"

#import <TargetConditionals.h>
#include <cstdint>
#include <vector>
#include <unordered_map>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#pragma clang diagnostic ignored "-Wquoted-include-in-framework-header"
#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>
#pragma clang diagnostic pop

static double medianIntensity(const cv::Mat &mat) {
    CV_Assert(mat.type() == CV_8UC1);
    int histogram[256] = {0};
    const int total = mat.rows * mat.cols;
    for (int y = 0; y < mat.rows; y++) {
        const uint8_t *row = mat.ptr<uint8_t>(y);
        for (int x = 0; x < mat.cols; x++) {
            histogram[row[x]] += 1;
        }
    }

    const int midpoint = total / 2;
    int cumulative = 0;
    for (int value = 0; value < 256; value++) {
        cumulative += histogram[value];
        if (cumulative >= midpoint) {
            return (double)value;
        }
    }
    return 128.0;
}

@implementation OpenCVSegmentationBridge

+ (nullable NSData *)regionLabelsFromGrayscale:(NSData *)grayscale
                                   subjectMask:(nullable NSData *)subjectMask
                                         width:(NSInteger)width
                                        height:(NSInteger)height {
    if (width <= 1 || height <= 1) { return nil; }

    const NSInteger pixelCount = width * height;
    if (grayscale.length != (NSUInteger)pixelCount) { return nil; }

    cv::Mat gray((int)height, (int)width, CV_8UC1, const_cast<void *>(grayscale.bytes));
    cv::Mat contrast;
    cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(2.0, cv::Size(8, 8));
    clahe->apply(gray, contrast);

    cv::Mat smooth;
    cv::bilateralFilter(contrast, smooth, 5, 24.0, 24.0);

    cv::Mat subjectBinary;
    bool hasSubjectMask = false;
    if (subjectMask && subjectMask.length == (NSUInteger)pixelCount) {
        cv::Mat rawMask((int)height, (int)width, CV_8UC1, const_cast<void *>(subjectMask.bytes));
        cv::threshold(rawMask, subjectBinary, 0.0, 255.0, cv::THRESH_BINARY);
        hasSubjectMask = cv::countNonZero(subjectBinary) > 0;
    }

    double median = medianIntensity(smooth);
    double low = std::max(10.0, median * 0.66);
    double high = std::max(low + 16.0, std::min(170.0, median * 1.33 + 12.0));

    cv::Mat edges;
    cv::Canny(smooth, edges, low, high, 3, true);

    cv::Mat gradX;
    cv::Mat gradY;
    cv::Mat absX;
    cv::Mat absY;
    cv::Mat gradient;
    cv::Sobel(smooth, gradX, CV_16S, 1, 0, 3);
    cv::Sobel(smooth, gradY, CV_16S, 0, 1, 3);
    cv::convertScaleAbs(gradX, absX);
    cv::convertScaleAbs(gradY, absY);
    cv::addWeighted(absX, 0.5, absY, 0.5, 0.0, gradient);

    cv::Mat gradEdges;
    cv::threshold(gradient, gradEdges, hasSubjectMask ? 20.0 : 24.0, 255.0, cv::THRESH_BINARY);

    cv::Mat lap16;
    cv::Mat lapAbs;
    cv::Mat lapEdges;
    cv::Laplacian(smooth, lap16, CV_16S, 3);
    cv::convertScaleAbs(lap16, lapAbs);
    cv::threshold(lapAbs, lapEdges, hasSubjectMask ? 18.0 : 22.0, 255.0, cv::THRESH_BINARY);

    cv::bitwise_or(edges, gradEdges, edges);
    cv::bitwise_or(edges, lapEdges, edges);

    if (hasSubjectMask) {
        cv::Mat subjectEdges;
        cv::Canny(smooth, subjectEdges, std::max(6.0, low * 0.6), std::max(24.0, high * 0.8), 3, true);
        cv::bitwise_and(subjectEdges, subjectBinary, subjectEdges);
        cv::bitwise_or(edges, subjectEdges, edges);
    }

    cv::Mat closeKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3));
    cv::morphologyEx(edges, edges, cv::MORPH_CLOSE, closeKernel, cv::Point(-1, -1), 1);
    cv::Mat thinKernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(2, 2));
    cv::erode(edges, edges, thinKernel, cv::Point(-1, -1), 1);

    cv::Mat fillMask;
    cv::bitwise_not(edges, fillMask);

    cv::Mat components;
    int componentCount = cv::connectedComponents(fillMask, components, 8, CV_32S);
    if (componentCount <= 1) { return nil; }

    std::vector<int> componentSizes((size_t)componentCount, 0);
    for (int y = 0; y < (int)height; y++) {
        const int *componentRow = components.ptr<int>(y);
        for (int x = 0; x < (int)width; x++) {
            int component = componentRow[x];
            if (component > 0) {
                componentSizes[(size_t)component] += 1;
            }
        }
    }

    cv::Mat toneBin;
    cv::divide(smooth, cv::Scalar(12), toneBin);

    const int largeSubjectThreshold = std::max(320, (int)pixelCount / 16);
    const int largeBackgroundThreshold = std::max(420, (int)pixelCount / 9);

    cv::Mat output = cv::Mat::zeros((int)height, (int)width, CV_32S);
    std::unordered_map<uint64_t, int> remap;
    remap.reserve((size_t)componentCount * 6);
    int nextID = 1;

    for (int y = 0; y < (int)height; y++) {
        const int *componentRow = components.ptr<int>(y);
        const uint8_t *toneRow = toneBin.ptr<uint8_t>(y);
        const uint8_t *gradientRow = gradient.ptr<uint8_t>(y);
        const uint8_t *subjectRow = hasSubjectMask ? subjectBinary.ptr<uint8_t>(y) : nullptr;
        int *outRow = output.ptr<int>(y);
        for (int x = 0; x < (int)width; x++) {
            int component = componentRow[x];
            if (component <= 0) {
                outRow[x] = 0;
                continue;
            }

            const bool inSubject = hasSubjectMask && subjectRow[x] > 0;
            int toneGroup = inSubject ? (int)toneRow[x] : (int)toneRow[x] / 2;

            if (!inSubject && gradientRow[x] < 14) {
                toneGroup = toneGroup / 2;
            }

            int localGroup = toneGroup;
            int componentSize = componentSizes[(size_t)component];
            int largeThreshold = inSubject ? largeSubjectThreshold : largeBackgroundThreshold;
            if (componentSize > largeThreshold) {
                int cell = inSubject ? 11 : 17;
                int sx = x / cell;
                int sy = y / cell;
                localGroup = localGroup * 4096 + sy * 128 + sx;
            }

            uint64_t key = (static_cast<uint64_t>(component) << 32) | static_cast<uint32_t>(localGroup);
            auto result = remap.emplace(key, nextID);
            if (result.second) {
                nextID += 1;
            }
            outRow[x] = result.first->second;
        }
    }

    // Fill thin contour gaps so Swift can build closed paint regions reliably.
    for (int pass = 0; pass < 3; pass++) {
        for (int y = 1; y < (int)height - 1; y++) {
            int *row = output.ptr<int>(y);
            const int *up = output.ptr<int>(y - 1);
            const int *down = output.ptr<int>(y + 1);
            for (int x = 1; x < (int)width - 1; x++) {
                if (row[x] != 0) { continue; }
                int neighbor = row[x - 1];
                if (neighbor == 0) { neighbor = row[x + 1]; }
                if (neighbor == 0) { neighbor = up[x]; }
                if (neighbor == 0) { neighbor = down[x]; }
                if (neighbor != 0) {
                    row[x] = neighbor;
                }
            }
        }
    }

    return [NSData dataWithBytes:output.data length:(NSUInteger)pixelCount * sizeof(int32_t)];
}

+ (nullable NSData *)refinedForegroundMaskFromRGBA:(NSData *)rgba
                                          seedMask:(nullable NSData *)seedMask
                                          hintMask:(nullable NSData *)hintMask
                                             width:(NSInteger)width
                                            height:(NSInteger)height {
    if (width <= 1 || height <= 1) { return nil; }

    const NSInteger pixelCount = width * height;
    if (rgba.length != (NSUInteger)pixelCount * 4) { return nil; }

    cv::Mat rgbaMat((int)height, (int)width, CV_8UC4, const_cast<void *>(rgba.bytes));
    cv::Mat bgr;
    cv::cvtColor(rgbaMat, bgr, cv::COLOR_RGBA2BGR);

    cv::Mat gcMask((int)height, (int)width, CV_8UC1, cv::Scalar(cv::GC_PR_BGD));
    bool hasForeground = false;
    bool hasBackground = false;
    int minFGX = (int)width;
    int minFGY = (int)height;
    int maxFGX = -1;
    int maxFGY = -1;

    if (seedMask && seedMask.length == (NSUInteger)pixelCount) {
        cv::Mat rawSeed((int)height, (int)width, CV_8UC1, const_cast<void *>(seedMask.bytes));
        for (int y = 0; y < (int)height; y++) {
            const uint8_t *seedRow = rawSeed.ptr<uint8_t>(y);
            uint8_t *maskRow = gcMask.ptr<uint8_t>(y);
            for (int x = 0; x < (int)width; x++) {
                if (seedRow[x] > 0) {
                    maskRow[x] = cv::GC_PR_FGD;
                    hasForeground = true;
                    if (x < minFGX) { minFGX = x; }
                    if (x > maxFGX) { maxFGX = x; }
                    if (y < minFGY) { minFGY = y; }
                    if (y > maxFGY) { maxFGY = y; }
                }
            }
        }
    }

    if (hintMask && hintMask.length == (NSUInteger)pixelCount) {
        cv::Mat rawHints((int)height, (int)width, CV_8UC1, const_cast<void *>(hintMask.bytes));
        for (int y = 0; y < (int)height; y++) {
            const uint8_t *hintRow = rawHints.ptr<uint8_t>(y);
            uint8_t *maskRow = gcMask.ptr<uint8_t>(y);
            for (int x = 0; x < (int)width; x++) {
                if (hintRow[x] == 1) {
                    maskRow[x] = cv::GC_FGD;
                    hasForeground = true;
                    if (x < minFGX) { minFGX = x; }
                    if (x > maxFGX) { maxFGX = x; }
                    if (y < minFGY) { minFGY = y; }
                    if (y > maxFGY) { maxFGY = y; }
                } else if (hintRow[x] == 2) {
                    maskRow[x] = cv::GC_BGD;
                    hasBackground = true;
                }
            }
        }
    }

    if (!hasForeground) { return nil; }

    if (!hasBackground) {
        int border = std::max(2, std::min((int)width, (int)height) / 24);
        for (int y = 0; y < (int)height; y++) {
            uint8_t *maskRow = gcMask.ptr<uint8_t>(y);
            for (int x = 0; x < (int)width; x++) {
                if (x < border || y < border || x >= (int)width - border || y >= (int)height - border) {
                    maskRow[x] = cv::GC_BGD;
                }
            }
        }

        if (maxFGX >= minFGX && maxFGY >= minFGY) {
            int boxW = maxFGX - minFGX + 1;
            int boxH = maxFGY - minFGY + 1;
            int padX = std::max(6, boxW / 5);
            int padY = std::max(6, boxH / 5);
            int keepMinX = std::max(0, minFGX - padX);
            int keepMaxX = std::min((int)width - 1, maxFGX + padX);
            int keepMinY = std::max(0, minFGY - padY);
            int keepMaxY = std::min((int)height - 1, maxFGY + padY);

            for (int y = 0; y < (int)height; y++) {
                uint8_t *maskRow = gcMask.ptr<uint8_t>(y);
                for (int x = 0; x < (int)width; x++) {
                    if (x < keepMinX || x > keepMaxX || y < keepMinY || y > keepMaxY) {
                        if (maskRow[x] != cv::GC_FGD) {
                            maskRow[x] = cv::GC_BGD;
                        }
                    }
                }
            }
        }
    }

    cv::Mat bgModel;
    cv::Mat fgModel;
    try {
        cv::grabCut(bgr, gcMask, cv::Rect(), bgModel, fgModel, 4, cv::GC_INIT_WITH_MASK);
    } catch (...) {
        return nil;
    }

    cv::Mat out((int)height, (int)width, CV_8UC1, cv::Scalar(0));
    for (int y = 0; y < (int)height; y++) {
        const uint8_t *maskRow = gcMask.ptr<uint8_t>(y);
        uint8_t *outRow = out.ptr<uint8_t>(y);
        for (int x = 0; x < (int)width; x++) {
            const uint8_t value = maskRow[x];
            outRow[x] = (value == cv::GC_FGD || value == cv::GC_PR_FGD) ? 255 : 0;
        }
    }

    if (hintMask && hintMask.length == (NSUInteger)pixelCount) {
        cv::Mat rawHints((int)height, (int)width, CV_8UC1, const_cast<void *>(hintMask.bytes));
        for (int y = 0; y < (int)height; y++) {
            const uint8_t *hintRow = rawHints.ptr<uint8_t>(y);
            uint8_t *outRow = out.ptr<uint8_t>(y);
            for (int x = 0; x < (int)width; x++) {
                if (hintRow[x] == 1) {
                    outRow[x] = 255;
                } else if (hintRow[x] == 2) {
                    outRow[x] = 0;
                }
            }
        }
    }

    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(3, 3));
    cv::morphologyEx(out, out, cv::MORPH_CLOSE, kernel, cv::Point(-1, -1), 1);

    return [NSData dataWithBytes:out.data length:(NSUInteger)pixelCount];
}

@end

NSData * _Nullable OpenCVRegionLabelsFromGrayscale(
    NSData *grayscale,
    NSData * _Nullable subjectMask,
    NSInteger width,
    NSInteger height
) {
    return [OpenCVSegmentationBridge
        regionLabelsFromGrayscale:grayscale
                       subjectMask:subjectMask
                             width:width
                            height:height];
}

NSData * _Nullable OpenCVRefinedForegroundMaskFromRGBA(
    NSData *rgba,
    NSData * _Nullable seedMask,
    NSData * _Nullable hintMask,
    NSInteger width,
    NSInteger height
) {
    return [OpenCVSegmentationBridge
        refinedForegroundMaskFromRGBA:rgba
                            seedMask:seedMask
                            hintMask:hintMask
                               width:width
                              height:height];
}
