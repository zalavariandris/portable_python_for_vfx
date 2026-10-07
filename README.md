# Portable Python for VFX
(VFX Platform 2025)

setup donwloads:
- portable python 3.11 (or .python-version)
- ffmpeg
- OpenColorIO (todo)


## Setup


### Setup Python 

Run `setup_python.bat`.

Setup does three things:

1. Downloads uv into `bin/`.
2. Downloads Python into `python/`.
3. Creates `.venv/` using that downloaded Python.

If `.python-version` exists, it will use its version.


### Setup FFMpeg 

Run `download_ffmpeg.bat`.
