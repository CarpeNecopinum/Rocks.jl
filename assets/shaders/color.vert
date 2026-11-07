#version 450
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec4 a_color;
layout(location = 0) out vec4 v_color;
layout(std140, set = 1, binding = 0) uniform UniformBlock {
    mat4 proj;
} ubo;

void main() {
    gl_Position = ubo.proj * vec4(a_pos, 0.0, 1.0);
    v_color = a_color;
}
