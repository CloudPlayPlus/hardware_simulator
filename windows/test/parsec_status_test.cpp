#include "../parsec-vdd.h"
#include <stdexcept>
#define CHECK(x) do { if (!(x)) throw std::runtime_error(#x); } while (0)
int main() {
    using namespace parsec_vdd;
    CHECK(ClassifyDeviceStatus(DN_DRIVER_LOADED | DN_HAS_PROBLEM, CM_PROB_FAILED_POST_START) == DEVICE_DRIVER_ERROR);
    CHECK(ClassifyDeviceStatus(DN_STARTED | DN_HAS_PROBLEM, CM_PROB_DISABLED) == DEVICE_DISABLED);
    CHECK(ClassifyDeviceStatus(DN_STARTED | DN_DRIVER_LOADED, 0) == DEVICE_OK);
    CHECK(ClassifyDeviceStatus(DN_HAS_PROBLEM, CM_PROB_NEED_RESTART) == DEVICE_RESTART_REQUIRED);
    return 0;
}
