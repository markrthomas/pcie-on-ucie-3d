# syntax=docker/dockerfile:1.7
# =============================================================================
# pcie-on-ucie-3d DV toolchain image — NO OSS CAD Suite.  Pins every tool so CI
# caches on tool versions (not the source).  Stages:
#   builder : compile Verilator / Yosys(+slang) / SBY from source into /opt
#   tools   : runtime toolchain (what CI uses via `container:`), no repo baked in
#   full    : FROM tools + the repo + entrypoint (Railway / local batch)
# CI builds `--target tools`; Railway builds the default (full) stage.
# No `RUN --mount=type=secret` (Railway's builder rejects it).
# =============================================================================
ARG UBUNTU=ubuntu:24.04

# ---- builder ----------------------------------------------------------------
FROM ${UBUNTU} AS builder
ARG VERILATOR_REF=v5.050
ARG YOSYS_REF=47595d984
ARG SBY_REF=main
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git make cmake g++ ccache autoconf flex bison libfl-dev \
      help2man perl python3 python3-dev zlib1g-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*

# Verilator (from source; apt 5.020 cannot compile uvm-core)
RUN git clone https://github.com/verilator/verilator /tmp/verilator \
    && cd /tmp/verilator && git checkout ${VERILATOR_REF} \
    && autoconf && ./configure --prefix=/opt/verilator && make -j"$(nproc)" && make install \
    && rm -rf /tmp/verilator

# Yosys with the native slang frontend (SystemVerilog) + SBY.
# This Yosys ref uses the CMake build (slang is built in natively via frontends/slang);
# the legacy `make config-gcc` flow no longer exists at this commit.  tcl/readline/
# editline/ffi OFF (not needed for formal); -j capped so the heavy slang TUs fit a
# CI runner's RAM.
RUN git clone --recurse-submodules https://github.com/YosysHQ/yosys /tmp/yosys \
    && cd /tmp/yosys && git checkout ${YOSYS_REF} && git submodule update --init --recursive \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/yosys \
        -DYOSYS_WITHOUT_TCL=ON -DYOSYS_WITHOUT_READLINE=ON \
        -DYOSYS_WITHOUT_EDITLINE=ON -DYOSYS_WITHOUT_LIBFFI=ON \
    && cmake --build build -j"$(( $(nproc) < 4 ? $(nproc) : 4 ))" \
    && cmake --install build \
    && rm -rf /tmp/yosys
RUN git clone https://github.com/YosysHQ/sby /tmp/sby \
    && cd /tmp/sby && git checkout ${SBY_REF} && make install PREFIX=/opt/sby \
    && rm -rf /tmp/sby

# ---- tools (CI runs the jobs in this stage) ---------------------------------
FROM ${UBUNTU} AS tools
ARG WITH_CLAUDE=0
ARG YICES_VERSION=2.6.5
ENV DEBIAN_FRONTEND=noninteractive
# optional extra CA certs (TLS-intercept proxies): drop *.crt into docker/extra_ca/
COPY docker/extra_ca/ /usr/local/share/ca-certificates/
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git make g++ ccache python3 python3-venv python3-dev \
      iverilog libsystemc-dev z3 zlib1g-dev liblz4-dev xz-utils \
    && update-ca-certificates || true \
    && rm -rf /var/lib/apt/lists/*
# yices2 (preferred SMT solver for formal `cover`; z3 can OOM on deeper covers)
RUN curl -fsSL https://github.com/SRI-CSL/yices2/releases/download/Yices-${YICES_VERSION}/yices-${YICES_VERSION}-x86_64-pc-linux-gnu-static-gmp.tar.gz \
      -o /tmp/yices.tgz \
    && tar -xzf /tmp/yices.tgz -C /opt && rm /tmp/yices.tgz \
    && for b in /opt/yices-${YICES_VERSION}/bin/*; do ln -sf "$b" /usr/local/bin/; done
COPY --from=builder /opt/verilator /opt/verilator
COPY --from=builder /opt/yosys /opt/yosys
COPY --from=builder /opt/sby /opt/sby
ENV PATH=/opt/venv/bin:/opt/verilator/bin:/opt/yosys/bin:/opt/sby/bin:/usr/local/bin:/usr/bin:/bin
# Python DV libs (cocotb / pyuvm / pyvsc) in a venv
COPY dv/cocotb/requirements.txt /tmp/requirements.txt
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt
# optional: Claude Code CLI for the agent swarm (docker/swarm.sh)
RUN if [ "$WITH_CLAUDE" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends nodejs npm \
      && npm install -g @anthropic-ai/claude-code \
      && rm -rf /var/lib/apt/lists/*; fi

# ---- full (Railway / local batch; NOT used by GitHub CI) --------------------
FROM tools AS full
WORKDIR /repo
COPY . /repo
RUN chmod +x docker/*.sh || true
ENTRYPOINT ["/repo/docker/entrypoint.sh"]
