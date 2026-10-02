#ifndef RUNNER_FULLSCREEN_MOUSE_GUARD_H_
#define RUNNER_FULLSCREEN_MOUSE_GUARD_H_

#include <windows.h>

/// Plans only bottom-edge corrections, including direct passage to a monitor below.
inline bool PlanFullscreenBottomEdge(const RECT& screen, const POINT& point,
                                     const RECT* below, POINT* target) {
  constexpr LONG kTriggerBand = 3;
  if (target == nullptr || point.x < screen.left || point.x >= screen.right ||
      point.y < screen.bottom - kTriggerBand || point.y >= screen.bottom) {
    return false;
  }
  *target = point;
  if (below != nullptr && point.x >= below->left && point.x < below->right &&
      below->top <= screen.bottom && below->bottom > screen.bottom) {
    target->y = screen.bottom;
  } else {
    target->y = screen.bottom - kTriggerBand - 1;
  }
  return true;
}

#endif
