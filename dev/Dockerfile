FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    bash \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Create DATA directory (mimics PCS filesystem)
RUN mkdir -p /DATA

WORKDIR /root
