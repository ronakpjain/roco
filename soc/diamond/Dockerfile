# Lattice Diamond batch container for the roco SoC.
#
# Base is CentOS 7: Diamond 3.x predates modern glibc, and the container
# sidesteps Arch's libraries entirely. The installer itself is
# login-walled on lattice-semi.com, so it is NOT fetched here — drop the
# .run file into the build context (see build.sh) and pass its exact name in.
#
# Build (on Hercules, via build.sh):
#   docker build --build-arg INSTALLER_RUN=<file> --build-arg DIAMOND_VERSION=3.14 .
ARG DIAMOND_VERSION=3.14
FROM centos:7

ARG DIAMOND_VERSION
ARG INSTALLER_RUN

# No X server needed: this is a Qt Installer Framework bundle, which runs
# headless with the minimal platform plus an auto-click script
# (see install.qs). X client libs stay for the Diamond tools themselves.
# CentOS 7 went EOL in 2024 and its mirrorlist is dead; use the vault.
RUN sed -i 's|^mirrorlist=|#mirrorlist=|; s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' /etc/yum.repos.d/CentOS-*.repo \
 && yum install -y \
      libX11 libXext libXft libSM libICE libXtst mesa-libGL mesa-libGLU \
      tar gzip perl which \
 && yum clean all \
 && rm -rf /var/cache/yum

COPY installer/${INSTALLER_RUN} /tmp/diamond-installer.run
COPY install.qs /tmp/install.qs

# Qt Installer Framework bundle: --console plus an auto-click --script.
# If flags/pages differ for a newer Diamond release, the first build log
# will say so — adjust install.qs and note the working combination in
# soc/diamond/README.md.
RUN chmod +x /tmp/diamond-installer.run \
 && QT_QPA_PLATFORM=minimal /tmp/diamond-installer.run --console --script /tmp/install.qs --prefix /usr/local/diamond \
 && rm -f /tmp/diamond-installer.run /tmp/install.qs

ENV DIAMOND_VERSION=${DIAMOND_VERSION}
ENV PATH=/usr/local/diamond/bin/lin64:$PATH
# FlexLM: node-locked license bind-mounted read-only at /lic (see run.sh).
ENV LM_LICENSE_FILE=/lic/license.dat
# Diamond writes dotfiles; keep them off the bind mounts.
ENV HOME=/home/diamond
RUN mkdir -p /home/diamond /work && chmod 777 /home/diamond /work
WORKDIR /work

ENTRYPOINT ["diamondc"]
