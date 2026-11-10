FROM debian:bookworm-slim

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential bc bison flex cpio file wget curl ca-certificates git \
        rsync unzip xz-utils bzip2 gzip patch perl python3 python3-setuptools \
        libncurses-dev libssl-dev locales which gawk texinfo help2man \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 FORCE_UNSAFE_CONFIGURE=1

RUN useradd -m -u 1000 builder
USER builder
WORKDIR /home/builder
