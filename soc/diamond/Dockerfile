# Lattice Diamond batch container for the roco SoC.
#
# Base is CentOS 7: Diamond 3.x predates modern glibc, and the container
# sidesteps Arch's libraries entirely. The installer tarball itself is
# login-walled on lattice-semi.com, so it is NOT fetched here — drop it
# into the build context (see build.sh) and pass its exact name in.
#
# Build (on Hercules, via build.sh):
#   docker build --build-arg INSTALLER_TGZ=<file> --build-arg DIAMOND_VERSION=3.14 .
ARG DIAMOND_VERSION=3.14
FROM centos:7

ARG DIAMOND_VERSION
ARG INSTALLER_TGZ

# Diamond batch needs basic X client libs even headless, plus tar/perl for
# the installer itself. Keep the list small; add motif/Xvfb only if a
# future Diamond version's installer demands a display (see README).
RUN yum install -y \
      libX11 libXext libXft libSM libICE libXtst \
      tar gzip perl which \
 && yum clean all \
 && rm -rf /var/cache/yum

COPY installer/${INSTALLER_TGZ} /tmp/diamond-installer.tgz

# InstallBuilder-based installer, unattended. If these flags differ for a
# newer Diamond release, the first build log will say so — adjust and note
# the working combination in soc/diamond/README.md.
RUN mkdir -p /tmp/diamond-install \
 && tar -xzf /tmp/diamond-installer.tgz -C /tmp/diamond-install \
 && /tmp/diamond-install/*.bin --mode unattended --prefix /usr/local/diamond \
 && rm -rf /tmp/diamond-install /tmp/diamond-installer.tgz

ENV DIAMOND_VERSION=${DIAMOND_VERSION}
ENV PATH=/usr/local/diamond/${DIAMOND_VERSION}/bin/lin64:$PATH
# FlexLM: node-locked license bind-mounted read-only at /lic (see run.sh).
ENV LM_LICENSE_FILE=/lic/license.dat
# Diamond writes dotfiles; keep them off the bind mounts.
ENV HOME=/home/diamond
RUN mkdir -p /home/diamond /work && chmod 777 /home/diamond /work
WORKDIR /work

ENTRYPOINT ["diamondc"]
