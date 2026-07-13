#pragma once

#include <stdbool.h>
#include <stdatomic.h>

typedef atomic_int VPServiceState;

enum {
  VPServiceStatePending = 0,
  VPServiceStateAvailable = 1,
  VPServiceStateUnavailable = 2,
};

#define VP_SERVICE_STATE_INITIALIZER ATOMIC_VAR_INIT(VPServiceStatePending)

static inline bool vp_service_available(VPServiceState *state) {
  return atomic_load_explicit(state, memory_order_acquire) ==
         VPServiceStateAvailable;
}

static inline bool vp_service_complete(VPServiceState *state, bool available) {
  int expected = VPServiceStatePending;
  int desired = available ? VPServiceStateAvailable : VPServiceStateUnavailable;
  return atomic_compare_exchange_strong_explicit(
      state, &expected, desired, memory_order_release, memory_order_relaxed);
}

static inline bool vp_service_expire(VPServiceState *state) {
  int expected = VPServiceStatePending;
  return atomic_compare_exchange_strong_explicit(
      state, &expected, VPServiceStateUnavailable, memory_order_release,
      memory_order_relaxed);
}
