#!/usr/bin/env python3
"""Generate realistic WebGL 1.0 (GLSL ES 1.00) and WebGL 2.0 (GLSL ES 3.00) shader corpora."""
import os
import sys

THREEJS_PBR_VERT = """\
#define USE_MAP
#define USE_NORMALMAP
precision highp float;

attribute vec3 position;
attribute vec3 normal;
attribute vec2 uv;
attribute vec4 tangent;

uniform mat4 modelMatrix;
uniform mat4 modelViewMatrix;
uniform mat4 projectionMatrix;
uniform mat3 normalMatrix;
uniform vec3 cameraPosition;

varying vec2 vUv;
varying vec3 vWorldPos;
varying vec3 vNormal;
varying vec3 vViewPosition;
varying vec4 vTangent;

void main() {
  vUv = uv;
  vec4 worldPosition = modelMatrix * vec4(position, 1.0);
  vWorldPos = worldPosition.xyz;
  vNormal = normalize(normalMatrix * normal);
  vTangent = vec4(normalize(normalMatrix * tangent.xyz), tangent.w);
  vec4 mvPosition = modelViewMatrix * vec4(position, 1.0);
  vViewPosition = -mvPosition.xyz;
  gl_Position = projectionMatrix * mvPosition;
}
"""

THREEJS_PBR_FRAG = """\
#extension GL_OES_standard_derivatives : enable
#extension GL_EXT_shader_texture_lod : enable
#define NUM_DIR_LIGHTS 2
#define USE_MAP
#define USE_NORMALMAP
#define USE_ENVMAP
precision highp float;
precision mediump int;

struct DirectionalLight {
  vec3 direction;
  vec3 color;
};

struct PhysicalMaterial {
  vec3 diffuseColor;
  float roughness;
  vec3 specularColor;
  float metalness;
};

struct GeometricContext {
  vec3 position;
  vec3 normal;
  vec3 viewDir;
};

uniform vec3 diffuse;
uniform float opacity;
uniform float roughness;
uniform float metalness;
uniform float envMapIntensity;
uniform vec3 ambientLightColor;
uniform DirectionalLight directionalLights[2];
uniform sampler2D map;
uniform sampler2D normalMap;
uniform sampler2D roughnessMap;
uniform samplerCube envMap;

varying vec2 vUv;
varying vec3 vWorldPos;
varying vec3 vNormal;
varying vec3 vViewPosition;
varying vec4 vTangent;

const float PI = 3.14159265359;
const float RECIPROCAL_PI = 0.31830988618;

float pow2(const in float x) {
  return x * x;
}

float saturate(const in float a) {
  return clamp(a, 0.0, 1.0);
}

vec3 F_Schlick(const in vec3 f0, const in float f90, const in float dotVH) {
  float fresnel = exp2((-5.55473 * dotVH - 6.98316) * dotVH);
  return f0 * (1.0 - fresnel) + (f90 * fresnel);
}

float V_GGX_SmithCorrelated(const in float alpha, const in float dotNL, const in float dotNV) {
  float a2 = pow2(alpha);
  float gv = dotNL * sqrt(a2 + (1.0 - a2) * pow2(dotNV));
  float gl = dotNV * sqrt(a2 + (1.0 - a2) * pow2(dotNL));
  return 0.5 / max(gv + gl, 0.0001);
}

float D_GGX(const in float alpha, const in float dotNH) {
  float a2 = pow2(alpha);
  float denom = pow2(dotNH) * (a2 - 1.0) + 1.0;
  return RECIPROCAL_PI * a2 / pow2(denom);
}

vec3 BRDF_GGX(const in vec3 lightDir, const in vec3 viewDir, const in vec3 normal, const in vec3 f0, const in float roughnessVal) {
  float alpha = pow2(roughnessVal);
  vec3 halfDir = normalize(lightDir + viewDir);
  float dotNL = saturate(dot(normal, lightDir));
  float dotNV = saturate(dot(normal, viewDir));
  float dotNH = saturate(dot(normal, halfDir));
  float dotVH = saturate(dot(viewDir, halfDir));
  vec3 F = F_Schlick(f0, 1.0, dotVH);
  float V = V_GGX_SmithCorrelated(alpha, dotNL, dotNV);
  float D = D_GGX(alpha, dotNH);
  return F * (V * D);
}

vec3 perturbNormal2Arb(vec3 eye_pos, vec3 surf_norm, vec3 mapN) {
  vec3 q0 = dFdx(eye_pos.xyz);
  vec3 q1 = dFdy(eye_pos.xyz);
  vec2 st0 = dFdx(vUv.st);
  vec2 st1 = dFdy(vUv.st);
  vec3 N = normalize(surf_norm);
  vec3 q1perp = cross(q1, N);
  vec3 q0perp = cross(N, q0);
  vec3 T = q1perp * st0.x + q0perp * st1.x;
  vec3 B = q1perp * st0.y + q0perp * st1.y;
  float det = max(dot(T, T), dot(B, B));
  float scale = (det == 0.0) ? 0.0 : inversesqrt(det);
  return normalize(T * (mapN.x * scale) + B * (mapN.y * scale) + N * mapN.z);
}

vec3 ACESFilmicToneMapping(vec3 color) {
  color *= 0.6;
  return clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);
}

void main() {
  vec4 diffuseColor = vec4(diffuse, opacity);
  vec4 sampledDiffuseColor = texture2D(map, vUv);
  diffuseColor *= sampledDiffuseColor;

  float roughnessFactor = roughness;
  vec4 texelRoughness = texture2D(roughnessMap, vUv);
  roughnessFactor *= texelRoughness.g;
  roughnessFactor = clamp(roughnessFactor, 0.04, 1.0);

  vec3 normal = normalize(vNormal);
  vec3 mapN = texture2D(normalMap, vUv).xyz * 2.0 - 1.0;
  normal = perturbNormal2Arb(-vViewPosition, normal, mapN);

  PhysicalMaterial material;
  material.diffuseColor = diffuseColor.rgb * (1.0 - metalness);
  material.roughness = roughnessFactor;
  material.specularColor = mix(vec3(0.04), diffuseColor.rgb, metalness);
  material.metalness = metalness;

  GeometricContext geometry;
  geometry.position = -vViewPosition;
  geometry.normal = normal;
  geometry.viewDir = normalize(vViewPosition);

  vec3 totalDirect = vec3(0.0);
  for (int i = 0; i < 2; i++) {
    vec3 lDir = normalize(directionalLights[i].direction);
    float dotNL = saturate(dot(geometry.normal, lDir));
    vec3 irradiance = dotNL * directionalLights[i].color;
    vec3 diff = irradiance * material.diffuseColor * RECIPROCAL_PI;
    vec3 spec = irradiance * BRDF_GGX(lDir, geometry.viewDir, geometry.normal, material.specularColor, material.roughness);
    totalDirect += diff + spec;
  }

  vec3 indirect = ambientLightColor * material.diffuseColor;
  vec3 reflectVec = reflect(-geometry.viewDir, geometry.normal);
  float mip = material.roughness * 6.0;
  vec3 envColor = textureCubeLodEXT(envMap, reflectVec, mip).rgb * envMapIntensity;
  indirect += envColor * material.specularColor;

  vec3 outColor = ACESFilmicToneMapping(totalDirect + indirect);
  gl_FragColor = vec4(outColor, diffuseColor.a);
}
"""

SHADERTOY_ES300_VERT = """\
#version 300 es
precision highp float;

layout(location = 0) in vec2 aPosition;
out vec2 vUv;

void main() {
  vUv = aPosition * 0.5 + 0.5;
  gl_Position = vec4(aPosition, 0.0, 1.0);
}
"""

SHADERTOY_ES300_FRAG = """\
#version 300 es
precision highp float;
precision highp int;

layout(std140) uniform ShaderGlobals {
  vec3 iResolution;
  float iTime;
  vec4 iMouse;
  int iFrame;
};

uniform sampler2D uChannel0;
uniform sampler2D uChannel1;
uniform float uExposure;

in vec2 vUv;
layout(location = 0) out vec4 fragColor;

uint hashUint(uint x) {
  x = ((x >> 16u) ^ x) * 0x45d9f3bu;
  x = ((x >> 16u) ^ x) * 0x45d9f3bu;
  x = (x >> 16u) ^ x;
  return x;
}

float sdSphere(vec3 p, float s) {
  return length(p) - s;
}

float sdBox(vec3 p, vec3 b) {
  vec3 q = abs(p) - b;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sdTorus(vec3 p, vec2 t) {
  vec2 q = vec2(length(p.xz) - t.x, p.y);
  return length(q) - t.y;
}

float smin(float a, float b, float k) {
  float h = max(k - abs(a - b), 0.0) / k;
  return min(a, b) - h * h * k * 0.25;
}

mat2 rot2(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat2(c, -s, s, c);
}

vec2 mapScene(vec3 p) {
  vec3 q = p;
  q.xz = rot2(iTime * 0.35) * q.xz;
  float d1 = sdSphere(q - vec3(0.0, 0.25 + 0.2 * sin(iTime), 0.0), 0.55);
  float d2 = sdTorus(q - vec3(0.0, -0.1, 0.0), vec2(0.85, 0.22));
  float d3 = sdBox(q - vec3(0.0, -0.65, 0.0), vec3(1.5, 0.15, 1.5));
  float dObj = smin(d1, d2, 0.35);
  if (d3 < dObj) {
    return vec2(d3, 2.0);
  }
  return vec2(dObj, 1.0);
}

vec3 calcNormal(vec3 p) {
  vec2 e = vec2(0.001, -0.001);
  return normalize(
    e.xyy * mapScene(p + e.xyy).x +
    e.yyx * mapScene(p + e.yyx).x +
    e.yxy * mapScene(p + e.yxy).x +
    e.xxx * mapScene(p + e.xxx).x
  );
}

float calcAO(vec3 pos, vec3 nor) {
  float occ = 0.0;
  float sca = 1.0;
  for (int i = 0; i < 5; i++) {
    float h = 0.02 + 0.12 * float(i) / 4.0;
    float d = mapScene(pos + h * nor).x;
    occ += (h - d) * sca;
    sca *= 0.85;
  }
  return clamp(1.0 - 2.5 * occ, 0.0, 1.0);
}

void main() {
  vec2 uv = (vUv * 2.0 - 1.0) * vec2(iResolution.x / max(iResolution.y, 1.0), 1.0);
  vec3 ro = vec3(0.0, 0.6, 3.2);
  vec3 rd = normalize(vec3(uv, -1.6));

  float t = 0.0;
  float matId = -1.0;
  for (int i = 0; i < 64; i++) {
    vec3 p = ro + rd * t;
    vec2 h = mapScene(p);
    if (h.x < 0.001) {
      matId = h.y;
      break;
    }
    t += h.x;
    if (t > 20.0) {
      break;
    }
  }

  vec3 col = mix(vec3(0.05, 0.08, 0.14), vec3(0.18, 0.28, 0.42), vUv.y);
  if (matId > 0.0) {
    vec3 p = ro + rd * t;
    vec3 n = calcNormal(p);
    vec3 l = normalize(vec3(0.7, 0.9, 0.5));
    float diff = max(dot(n, l), 0.0);
    float ao = calcAO(p, n);
    vec3 base = (matId > 1.5) ? texture(uChannel0, p.xz * 0.5).rgb : textureLod(uChannel1, vUv, 1.0).rgb;
    vec4 noise = texelFetch(uChannel0, ivec2(int(hashUint(uint(iFrame)) & 63u), 0), 0);
    col = base * (0.15 + 0.85 * diff) * ao + noise.rgb * 0.01;
  }

  col = 1.0 - exp(-col * uExposure);
  fragColor = vec4(pow(col, vec3(0.4545)), 1.0);
}
"""

POSTPROCESS_2D_FRAG = """\
precision highp float;

uniform sampler2D uSceneTex;
uniform sampler2D uBloomTex;
uniform vec2 uTexelSize;
uniform float uBloomStrength;
uniform float uChromaticAberration;
uniform float uVignette;
uniform float uGamma;
uniform float uWeights[5];

varying vec2 vUv;

vec3 sampleChromatic(sampler2D tex, vec2 uv, vec2 dir, float amt) {
  float r = texture2D(tex, uv + dir * amt).r;
  float g = texture2D(tex, uv).g;
  float b = texture2D(tex, uv - dir * amt).b;
  return vec3(r, g, b);
}

vec3 blur5(sampler2D tex, vec2 uv, vec2 stepDir) {
  vec3 acc = texture2D(tex, uv).rgb * uWeights[0];
  for (int i = 1; i < 5; i++) {
    vec2 off = stepDir * float(i);
    acc += texture2D(tex, uv + off).rgb * uWeights[i];
    acc += texture2D(tex, uv - off).rgb * uWeights[i];
  }
  return acc;
}

void main() {
  vec2 centered = vUv - vec2(0.5);
  float dist = length(centered);
  vec2 dir = centered / max(dist, 0.0001);

  vec3 scene = sampleChromatic(uSceneTex, vUv, dir * uTexelSize, uChromaticAberration * dist * 8.0);
  vec3 bloomH = blur5(uBloomTex, vUv, vec2(uTexelSize.x, 0.0));
  vec3 bloomV = blur5(uBloomTex, vUv, vec2(0.0, uTexelSize.y));
  vec3 color = scene + (bloomH + bloomV) * 0.5 * uBloomStrength;

  float vig = smoothstep(0.95, 0.25, dist * uVignette);
  color *= mix(0.65, 1.0, vig);
  color = color / (color + vec3(1.0));
  color = pow(max(color, vec3(0.0)), vec3(1.0 / max(uGamma, 0.01)));
  gl_FragColor = vec4(color, 1.0);
}
"""


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-glsl-bench"
    os.makedirs(out_dir, exist_ok=True)
    files = {
        "threejs_pbr_es100.vert": THREEJS_PBR_VERT,
        "threejs_pbr_es100.frag": THREEJS_PBR_FRAG,
        "shadertoy_es300.vert": SHADERTOY_ES300_VERT,
        "shadertoy_es300.frag": SHADERTOY_ES300_FRAG,
        "postprocess_2d_es100.frag": POSTPROCESS_2D_FRAG,
    }
    for name, content in files.items():
        path = os.path.join(out_dir, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  wrote {name:28s} ({len(content):5d} B)")


if __name__ == "__main__":
    main()
