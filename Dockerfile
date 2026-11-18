# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS dependencies
ENV DEBIAN_FRONTEND=noninteractive GZ_VERSION=harmonic
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg && \
    curl -fsSL https://packages.osrfoundation.org/gazebo.gpg \
    -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg && \
    echo 'deb [signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] https://packages.osrfoundation.org/gazebo/ubuntu-stable noble main' \
    > /etc/apt/sources.list.d/gazebo-stable.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    gz-harmonic python3 python3-venv python3-protobuf \
    python3-gz-transport13 python3-gz-msgs10 \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    libgl1-mesa-dri libegl1 libgl1 xvfb x11-utils x11vnc fluxbox novnc websockify \
    supervisor fonts-dejavu-core procps && \
    rm -rf /var/lib/apt/lists/*
RUN python3 -m venv --system-site-packages /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY docker/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && \
    python -c 'from gz.transport13 import Node; from gz.msgs10.pose_pb2 import Pose; import cv2, pymavlink, MAVProxy' && \
    gst-inspect-1.0 x264enc >/dev/null && gst-inspect-1.0 avdec_h264 >/dev/null

FROM dependencies AS builder
ARG ARDUPILOT_REF=e96bd9053e6e1ad0b633872590d8ae8a0fe8e450
ARG ARDUPILOT_GAZEBO_REF=80dc9664dda7efd6c5d1a71a79198d1d6b708c0e
ARG BUILD_JOBS=4
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake pkg-config git patch python3-dev rsync gawk \
    libgz-sim8-dev libgz-rendering8-dev libgz-transport13-dev libgz-plugin2-dev \
    rapidjson-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev && \
    rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir empy==3.3.4 pexpect==4.9.0 future==1.0.0 setuptools wheel
RUN git init /src/ardupilot && cd /src/ardupilot && \
    git remote add origin https://github.com/ArduPilot/ardupilot.git && \
    git fetch --depth 1 origin "$ARDUPILOT_REF" && git checkout --detach FETCH_HEAD && \
    git submodule update --init --recursive --depth 1 && \
    ./waf configure --board sitl --disable-tests && ./waf copter -j "$BUILD_JOBS"
RUN git init /src/ardupilot_gazebo && cd /src/ardupilot_gazebo && \
    git remote add origin https://github.com/ArduPilot/ardupilot_gazebo.git && \
    git fetch --depth 1 origin "$ARDUPILOT_GAZEBO_REF" && git checkout --detach FETCH_HEAD
# COPY docker/patches/ardupilot-gazebo-camera.patch /tmp/camera.patch
# RUN cd /src/ardupilot_gazebo && git apply --check /tmp/camera.patch && git apply /tmp/camera.patch && \
#     cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF && \
#     cmake --build build -j "$BUILD_JOBS"
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake pkg-config git patch python3-dev rsync gawk \
    libgz-sim8-dev libgz-rendering8-dev libgz-transport13-dev libgz-plugin2-dev \
    rapidjson-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libopencv-dev cppzmq-dev && \
    rm -rf /var/lib/apt/lists/*
RUN cd /src/ardupilot_gazebo && \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF && \
    cmake --build build -j "$BUILD_JOBS"
COPY sim/plugins/WindFlag.cc /src/WindFlag.cc
RUN mkdir -p /out/plugins && \
    c++ -std=c++17 -shared -fPIC -O2 /src/WindFlag.cc -o /out/plugins/libWindFlag.so \
    $(pkg-config --cflags --libs gz-sim8 gz-plugin2-register gz-transport13) && \
    cp /src/ardupilot_gazebo/build/lib*Plugin.so /out/plugins/

FROM dependencies AS runtime
ENV PYTHONUNBUFFERED=1 PYTHONPATH=/opt/los \
    GZ_IP=127.0.0.1 GZ_PARTITION=los_docker \
    GZ_SIM_RESOURCE_PATH=/opt/los/sim/models:/opt/ardupilot_gazebo/models \
    GZ_SIM_SYSTEM_PLUGIN_PATH=/opt/plugins \
    DISPLAY=:99 QT_QPA_PLATFORM=xcb \
    LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=4 \
    LOS_API_HOST=0.0.0.0 LOS_API_PORT=8080 LOS_NO_PREVIEW=1 \
    LOS_CONTROL_MODE=guided LOS_DOCKER=1 LOS_GAZEBO_GUI=false
COPY --from=builder /src/ardupilot/build/sitl/bin/arducopter /opt/bin/arducopter
COPY --from=builder /src/ardupilot/COPYING.txt /opt/licenses/ardupilot-COPYING.txt
COPY --from=builder /src/ardupilot_gazebo/LICENSE.md /opt/licenses/ardupilot_gazebo-LICENSE.md
COPY --from=builder /src/ardupilot_gazebo/models /opt/ardupilot_gazebo/models
COPY --from=builder /out/plugins /opt/plugins
WORKDIR /opt/los
COPY los ./los
COPY sim ./sim
COPY ardupilot/params ./ardupilot/params
COPY docker ./docker
COPY tests ./tests
# RUN mkdir -p .runtime/local /run/los && \
#     python -m compileall -q los docker && \
#     python -c 'from los.sim.gz_bridge import Node, Pose; from los.api.server import ApiServer' && \
#     gz sdf -k sim/worlds/my_world.sdf && \
#     chmod +x docker/entrypoint.sh docker/run.sh
RUN mkdir -p .runtime/local /run/los && \
    python -m compileall -q los docker && \
    python -c 'from los.sim.gz_bridge import Node, Pose; from los.api.server import ApiServer' && \
    python -c 'import xml.etree.ElementTree as ET; ET.parse("sim/worlds/my_world.sdf")' && \
    python -c 'from pathlib import Path; [p.write_bytes(p.read_bytes().replace(bytes([13,10]), bytes([10]))) for p in (Path("docker/entrypoint.sh"), Path("docker/run.sh"))]' && \
    chmod +x docker/entrypoint.sh docker/run.sh

EXPOSE 8080 8081
STOPSIGNAL SIGTERM
HEALTHCHECK --start-period=120s --interval=10s --timeout=5s --retries=6 \
    CMD ["python", "/opt/los/docker/healthcheck.py"]
ENTRYPOINT ["/opt/los/docker/entrypoint.sh"]
