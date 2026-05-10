ARG DEBIAN_VERSION=bookworm
ARG ESSENTIA_COMMIT=4ec93bb757d639217a535452bf0b3142ae5e6387
ARG ENABLE_VAMP=1
ARG ENABLE_TENSORFLOW=1
ARG TENSORFLOW_USE_GPU=0
ARG TENSORFLOW_VERSION=2.13.0
ARG FFMPEG_VERSION=4.4.4

# ---- build stage ----------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libeigen3-dev \
    libyaml-dev \
    libfftw3-dev \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswresample-dev \
    libsamplerate0-dev \
    libtag1-dev \
    libchromaprint-dev \
    python3 \
    python3-dev \
    python3-numpy \
    git \
    ca-certificates \
    wget \
    curl \
    libx264-dev \
    libx265-dev \
    libvpx-dev \
    libmp3lame-dev \
    libopus-dev \
    libvorbis-dev \
    libass-dev \
    libfreetype6-dev \
    zlib1g-dev \
    libssl-dev \
    $(if [ "$(dpkg --print-architecture)" = "amd64" ]; then echo "nasm yasm"; fi) && \
    rm -rf /var/lib/apt/lists/*

ARG FFMPEG_VERSION
WORKDIR /opt
RUN curl -LO https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz && \
    tar xJf ffmpeg-${FFMPEG_VERSION}.tar.xz && \
    cd ffmpeg-${FFMPEG_VERSION} && \
    ./configure --prefix=/usr/local \
    --enable-gpl \
    --enable-nonfree \
    --enable-pic \
    --enable-shared \
    --disable-static \
    --enable-libx264 \
    --enable-libmp3lame \
    --enable-libopus \
    --enable-libvpx && \
    make -j$(nproc) && \
    make install && \
    cd /opt && \
    rm -rf ffmpeg-${FFMPEG_VERSION}*

ARG ENABLE_TENSORFLOW
ARG TENSORFLOW_USE_GPU
ARG TENSORFLOW_VERSION
COPY install_tensorflow.sh /opt/install_tensorflow.sh
RUN if [ "$ENABLE_TENSORFLOW" = "1" ]; then \
   bash /opt/install_tensorflow.sh "${TENSORFLOW_VERSION}" "${TENSORFLOW_USE_GPU}"; \
   fi

ARG ESSENTIA_COMMIT
RUN git clone --depth 1 https://github.com/MTG/essentia.git /opt/essentia && \
    cd /opt/essentia && \
    git fetch --depth 1 origin $ESSENTIA_COMMIT && \
    git checkout $ESSENTIA_COMMIT

WORKDIR /opt/essentia

ARG ENABLE_VAMP
RUN python3 waf configure \
    $( [ "$ENABLE_VAMP" = "1" ] && echo "--with-vamp" ) \
    $( [ "$ENABLE_TENSORFLOW" = "1" ] && echo "--with-tensorflow" ) \
    --with-python \
    --pythondir=$(python3 -c "import site; print(site.getsitepackages()[0])") && \
    python3 waf && \
    python3 waf install

# ---- slim build artifacts before copying to runtime ----
# Strip debug symbols from shared libs (saves 200-400 MB on TF libs alone)
RUN find /usr/local/lib -name '*.so*' -exec strip --strip-unneeded {} \; && \
    # Remove static libraries, headers, and build artifacts not needed at runtime
    find /usr/local/lib -name '*.a' -delete && \
    find /usr/local/lib -name '*.la' -delete && \
    find /usr/local -name '*.h' -delete && \
    find /usr/local -name '*.hpp' -delete && \
    rm -rf /usr/local/share/pkgconfig && \
    rm -rf /usr/local/include && \
    rm -rf /opt/essentia /opt/libtensorflow* /opt/install_tensorflow.sh && \
    rm -rf /root/.cache/pip 2>/dev/null; true

# ---- main stage ---------------------------------------------------------
FROM debian:${DEBIAN_VERSION}-slim
ENV DEBIAN_FRONTEND=noninteractive

# Install Python runtime and FFmpeg runtime libs
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-numpy python3-six ffmpeg \
        libfftw3-single3 \
        libtag1v5 \
        libyaml-0-2 \
        python-is-python3 && \
    rm -rf /var/lib/apt/lists/* && \
    # Clean up apt cache and docs to save space
    find /usr/share/doc -depth -type f ! -name 'copyright' -delete && \
    find /usr/share/man -type f -delete 2>/dev/null; true

# Copy Essentia C++ libraries from build stage (libessentia.so, etc.)
COPY --from=build /usr/local/lib /usr/local/lib/

# Copy Essentia Python package from build stage
# waf install with system python3-dev puts it in /usr/lib/python3/dist-packages/
COPY --from=build /usr/lib/python3*/dist-packages/essentia* /usr/lib/python3/dist-packages/

# Ensure shared library cache is up to date (includes TF libs and libessentia.so)
RUN ldconfig