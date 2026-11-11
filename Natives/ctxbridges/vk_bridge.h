#pragma once

#include <stdbool.h>

typedef struct {
    void* unused;
} vk_render_window_t;

// [fix16][DEAD-CODE] 零调用点，禁止接线（见 vk_bridge.m 顶部说明）。
// 保留声明仅为维持 vk_bridge.m 内 static 函数的引用关系。
void set_vk_bridge_tbl(void);
