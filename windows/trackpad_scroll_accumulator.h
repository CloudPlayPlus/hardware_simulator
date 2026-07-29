#ifndef FLUTTER_PLUGIN_TRACKPAD_SCROLL_ACCUMULATOR_H_
#define FLUTTER_PLUGIN_TRACKPAD_SCROLL_ACCUMULATOR_H_

#include <algorithm>
#include <cmath>

namespace hardware_simulator {

// Converts continuous trackpad deltas to an integral legacy wheel API while
// carrying the fractional remainder forward. This preserves cumulative
// distance without rounding every frame away from zero.
class TrackpadScrollAccumulator {
public:
  TrackpadScrollAccumulator(double output_units_per_input_unit,
                            double max_output_distance)
      : output_units_per_input_unit_(output_units_per_input_unit),
        max_output_distance_(max_output_distance) {}

  int Convert(double logical_distance, bool invert) {
    if (!std::isfinite(logical_distance)) {
      return 0;
    }

    const double direction = invert ? -1.0 : 1.0;
    const double converted =
        logical_distance * direction * output_units_per_input_unit_ + residual_;
    const double clamped =
        (std::clamp)(converted, -max_output_distance_, max_output_distance_);

    // Keep truncation as the only integer conversion. The tiny tolerance only
    // prevents exact rational totals such as 5 * 1.2 from landing immediately
    // below an integer because of binary floating-point representation.
    constexpr double kIntegerBoundaryTolerance = 1e-9;
    const double adjusted =
        clamped + std::copysign(kIntegerBoundaryTolerance, clamped);
    const int whole_units = static_cast<int>(adjusted);

    residual_ = clamped - whole_units;
    if (std::abs(residual_) < kIntegerBoundaryTolerance) {
      residual_ = 0;
    }
    return whole_units;
  }

 private:
  double output_units_per_input_unit_;
  double max_output_distance_;
  double residual_ = 0;
};

} // namespace hardware_simulator

#endif // FLUTTER_PLUGIN_TRACKPAD_SCROLL_ACCUMULATOR_H_
