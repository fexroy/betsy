# Betsy GPU Compressor

Betsy aims to be a GPU compressor for various modern GPU compression formats such as BC6H,
purposedly written in GLSL so that it can be easily incorporated into OpenGL and Vulkan projects.

Compute Shader support is **required**.

The goal is to achieve both high performance (via efficient GPU usage) and high quality compression.

At the moment it is WIP.

## How do I use it?

Run:
```
betsy input.hdr --codec=etc2 --quality=2 output.ktx
```

Run `betsy --help` for full description

## Build Instructions

### Ubuntu

```
# Debug
sudo apt install libsdl2-dev ninja-build
mkdir -p build/Debug
cd build/Debug
cmake ../.. -DCMAKE_BUILD_TYPE=Debug -GNinja
ninja
cd ../../bin/Debug
./betsy

# Release
sudo apt install libsdl2-dev ninja-build
mkdir -p build/Release
cd build/Release
cmake ../.. -DCMAKE_BUILD_TYPE=Release -GNinja
ninja
cd ../../bin/Release
./betsy
```

### Windows

TBD.
Build works on VS2019. CMake generation, but it will complain about SDL2 due to poorly setup sdl2-config.cmake.
You'll need to setup the paths to SDL2 by hand.

### Python scripts

We use [EnumIterator.py](https://github.com/darksylinc/EnumIterator) to generate strings out of enums like in C#.

We keep the generated cpp files in the repo up to date but if you want to generate them yourself, run:

```
cd scripts/EnumIterator
python2 Run.py
```

## Supported formats:

| Format  | State          |Status|
|---------|----------------|------|
| ETC1    | Done 			| <br/>Based on [rg-etc1](https://github.com/richgel999/rg-etc1).<br/>AMD Mesa Linux: Requires a very recent Mesa version due to a shader miscompilation issue. See [ticket](https://gitlab.freedesktop.org/mesa/mesa/-/issues/3044#note_515611).|
| EAC     | Done           | Used for R11, RG11 and ETC2_RGBA (for encoding the alpha component).<br/>Quality: Maximum, we use brute force to check all possible combinations.|
| BC6H UF | Done           | Unsigned variation of B6CH. GLSL port of [GPURealTimeBC6H](https://github.com/knarkowicz/GPURealTimeBC6H)|

**Does betsy produce the same quality as the original implementations they were based on? (or bit-exact output)?**

In theory yes. In practice there could have been bugs during the port/adaptation,
and in some cases there could be precision issues.

For example rg-etc1 used uint64 for storing error comparison, while we use a 32-bit float.
While I don't think this should make a difference, I could be wrong.

There could also be compiler/driver/hardware bugs causing the code to misbehave, as is more common with compute shaders.

**Did you write these codecs yourself?**

So far I only wrote the EAC codec from scratch, but I used [etc2_encoder](https://github.com/titilambert/packaging-efl/blob/master/src/static_libs/rg_etc/etc2_encoder.c) for reference, particularly figuring out the bit pattern of the bit output and the idea of just using brute force. Unfortunately this version had several bugs which is why I just wrote it from scratch.

The rest of the codecs were originally written for different shading languages or architectures. See the supported formats' table for references to the original implementations.


## Legal

See [LICENSE.md](LICENSE.md)