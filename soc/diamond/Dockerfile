# Lattice Diamond batch container for the roco SoC.
#
# Base is CentOS 7: Diamond 3.x predates modern glibc, and the container
# sidesteps Arch's libraries entirely. The installer itself is
# login-walled on lattice-semi.com, so it is NOT fetched here — drop the
# .run file into the build context (see build.sh) and pass its exact name in.
#
# Build (on Hercules, via build.sh):
#   docker build --build-arg INSTALLER_TGZ=<file> --build-arg DIAMOND_VERSION=3.14 .
ARG DIAMOND_VERSION=3.14
FROM centos:7

ARG DIAMOND_VERSION
ARG INSTALLER_RUN

# Diamond batch needs basic X client libs even headless, plus tar/perl for
# the installer itself. Keep the list small; add motif/Xvfb only if a
# future Diamond version's installer demands a display (see README).
# CentOS 7 went EOL in 2024 and its mirrorlist is dead; use the vault.
RUN sed -i 's|^mirrorlist=|#mirrorlist=|; s|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' /etc/yum.repos.d/CentOS-*.repo \
 && yum install -y \
      libX11 libXext libXft libSM libICE libXtst \
      tar gzip perl which \
 && yum clean all \
 && rm -rf /var/cache/yum

COPY installer/${INSTALLER_RUN} /tmp/diamond-installer.run

# InstallBuilder-based .run installer, unattended. If these flags differ
# for a newer Diamond release, the first build log will say so — adjust
# and note the working combination in soc/diamond/README.md.
RUN chmod +x /tmp/diamond-installer.run \
 && /tmp/diamond-installer.run --mode unattended --prefix /usr/local/diamond \
 && rm -f /tmp/diamond-installer.run

ENV DIAMOND_VERSION=${DIAMOND_VERSION}
ENV PATH=/usr/local/diamond/${DIAMOND_VERSION}/bin/lin64:$PATH
# FlexLM: node-locked license bind-mounted read-only at /lic (see run.sh).
ENV LM_LICENSE_FILE=/lic/license.dat
# Diamond writes dotfiles; keep them off the bind mounts.
ENV HOME=/home/diamond
RUN mkdir -p /home/diamond /work && chmod 777 /home/diamond /work
WORKDIR /work

ENTRYPOINT ["diamondc"]
