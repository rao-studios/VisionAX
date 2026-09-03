//
//  Classifier.hpp
//  CVisionAX
//
//  WHAT: Two ONNX Runtime sessions — image → features, (features + boxes) → probs.
//  IN:   Engine::classifyRegions
//  OUT:  OrtApi.hpp, ClassifierPreprocess.hpp
//  PIN:  TWO GRAPHS, NOT ONE, and the reason is arithmetic. A 1080p screenshot yields
//        ~1,000 boxes; two 7x7xC RoIAlign crops each is hundreds of megabytes of
//        activations. Chunking is the only way to bound that, and chunking a FUSED
//        graph would re-run the backbone per chunk. So the backbone runs once, its
//        feature tensor is handed to the head untouched, and only the head repeats.
//        (It is also the seam a CoreML backbone needs later: RoiAlign has no CoreML
//        kernel, so a single graph would be partitioned in the middle regardless.)
//        Sessions are stateless across Run, so one classifier serves many threads.
//

#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

#include <opencv2/core.hpp>

#include "visionax.h"

namespace visionax {

class Classifier {
public:
    struct Label {
        int32_t classIndex = 0;
        float confidence = 0;
    };

    Classifier(const std::string &backbonePath,
               const std::string &headPath,
               const vx_classifier_spec &spec);
    ~Classifier();

    Classifier(const Classifier &) = delete;
    Classifier &operator=(const Classifier &) = delete;

    /// One backbone pass, then the head in chunks. `regions` may be empty.
    std::vector<Label> classify(const cv::Mat &image,
                                const vx_region *regions,
                                int32_t count) const;

    const vx_classifier_spec &spec() const { return spec_; }

    void setLastError(const std::string &message);
    std::string lastError() const;

    int64_t backboneRuns() const { return backboneRuns_.load(); }
    int64_t headRuns() const { return headRuns_.load(); }

private:
    struct Impl;
    Impl *impl_;
    vx_classifier_spec spec_;
    mutable std::atomic<int64_t> backboneRuns_{0};
    mutable std::atomic<int64_t> headRuns_{0};
    mutable std::mutex errorMutex_;
    std::string lastError_;
};

}  // namespace visionax
