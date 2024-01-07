#!/bin/bash

SKIP_PROJECTS_RE="(^_|pe-)"
INCLUDE_PROJECTS_RE="${INCLUDE_PROJECTS_RE:-.*}"

BUILD_PLATFORM=$PF

case $BUILD_PLATFORM in
    debian-12-amd64)
        BUILD_HOST=192.168.47.25
        BUILD_HOST_PACKAGE="deb"
        BUILD_PACKAGE_ARCH="amd64"
        BUILD_CODENAME="bookworm"
        ;;
    debian-12-aarch64)
        BUILD_HOST=198.19.249.65
        BUILD_HOST_PACKAGE="deb"
        BUILD_PACKAGE_ARCH="arm64"
        BUILD_CODENAME="bookworm"
        ;;
    *)
        exit 1
        ;;
esac

PACKAGING_LOCATION=${PACKAGING_LOCATION:-file://../packaging}
VANAGON_LOCATION=${VANAGON_LOCATION:-file://../vanagon}
VANAGON_USE_MIRRORS=${VANAGON_USE_MIRRORS:-n}

WORKDIR="${TMPDIR}/vanagon-${BUILD_PLATFORM}"
ARTIFACTDIR="../artifacts/${BUILD_PLATFORM}"

export PACKAGING_LOCATION
export VANAGON_LOCATION
export VANAGON_USE_MIRRORS

set -e

function use_local_component_builds() {
    echo "**> use local component builds"
    while IFS= read -r -d '' CFN ; do
        FOUND_VERSION=
        WANT_VERSION=
        LOCATION=$(jq -r .location < $CFN)
        if [ "${LOCATION}" != "null" ] ; then
            COMPONENT=$(basename "$CFN" .json)
            rm $CFN.orig 2>/dev/null || true
            git checkout $CFN
            local WANT_VERSION=$(jq -r .version < $CFN)
            echo "want local $COMPONENT ${WANT_VERSION}"
            for X in ${COMPONENT}-vanagon ${COMPONENT} ; do
                if [ -d ../$X/output ] ; then
                    FOUND_VERSION=$(find ../$X/output -name "*.${BUILD_PLATFORM}.json" | sed -E 's/.*-([0-9]{8,9}.*)\.'${BUILD_PLATFORM}'.json/\1/g' | sort -hur | head -1)
                    echo "found local $X $FOUND_VERSION"
                    if mv $CFN $CFN.orig ; then
                        if jq ".location=\"file://../${X}/output\" | .version=\"${FOUND_VERSION}\"" < $CFN.orig > $CFN ; then
                            break
                        else
                            mv $CFN.orig $CFN
                        fi
                    fi
                fi
            done
        fi
    done < <(find ./configs/components -name '*.json' -type f -print0)
}

function cleanup() {
    echo "**> cleanup"
    find -E "${WORKDIR}/" -maxdepth 1 -mindepth 1 -not -iregex '.*\.(gem|gz|zip|xz)$' -exec rm -rf {} \; 2>/dev/null || \
        find "${WORKDIR}/" -maxdepth 1 -mindepth 1 -not -iregex '.*\.\(gem\|gz\|zip\|xz\)$' -exec rm -rf {} \; || \
            mkdir "${WORKDIR}"
    if [[ $BUILD_HOST_PACKAGE =~ *.deb ]] ; then
        ssh root@${BUILD_HOST} "dpkg -S /opt/puppetlabs 2>/dev/null | sed -e 's/, / /g' -e 's/: \/opt\/puppetlabs$//' | xargs apt -y purge" || true
    elif [[ $BUILD_HOST_PACKAGE =~ *.rpm ]] ; then
        ssh root@${BUILD_HOST} "rpm -qf /opt/puppetlabs/* 2>/dev/null | xargs yum remove -y && yum update"
    fi
    ssh root@${BUILD_HOST} "rm -rf /tmp/vanagon /opt/puppetlabs" || true

    [ -d "${ARTIFACTDIR}" ] || mkdir -p "${ARTIFACTDIR}"
}

function update_repo() {
    echo "**> update repo"
    pushd "${ARTIFACTDIR}"
    if find . -name "*.${BUILD_PACKAGE_ARCH}.${BUILD_HOST_PACKAGE}" -type f | tar -cf - -T -| ssh root@${BUILD_HOST} 'mkdir -p /tmp/vanagon-repo; tar -C /tmp/vanagon-repo -xvf -' ; then
        if [[ $BUILD_HOST_PACKAGE =~ *.deb ]] ; then
            ssh -t root@${BUILD_HOST} "cd /tmp/vanagon-repo && dpkg-scanpackages -m . > Packages && echo 'deb [trusted=yes] file:/tmp/vanagon-repo /' > /etc/apt/sources.list.d/vanagon.list"
        elif [[ $BUILD_HOST_PACKAGE =~ *.rpm ]] ; then
            ssh -t root@${BUILD_HOST} "cd /tmp/vanagon-repo && createrepo . && echo -e '[vanagon]\nname=Vanagon\nbaseurl=file:///tmp/vanagon-repo\nenabled=1\ngpgcheck=0' > /etc/yum.repos.d/vanagon.repo"
        fi
    fi
    popd
}

function artifacts_to_repo() {
    echo "**> artifacts to repo"
    find output -name "*${BUILD_CODENAME}*${BUILD_PACKAGE_ARCH}.${BUILD_HOST_PACKAGE}" -type f -exec cp {} "${ARTIFACTDIR}" \;
}

function build() {
    echo "********************************************"
    echo "** build: $1"
    echo "********************************************"

    cleanup
    update_repo

    VANAGON_USE_MIRRORS=$VANAGON_USE_MIRRORS VANAGON_LOCATION=$VANAGON_LOCATION \
        bundle exec vanagon build \
        -w "${WORKDIR}" \
        -r /tmp/vanagon \
        $1 \
        ${BUILD_PLATFORM} \
        ${BUILD_HOST}

    artifacts_to_repo
}

function setup_host_to_build() {
  echo "**> setup host to build"
  case $BUILD_HOST_PACKAGE in
    deb)
      ssh root@${BUILD_HOST} 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dpkg-dev' ;;
    rpm)
      ssh root@${BUILD_HOST} 'yum -y groupinstall "Development Tools"' ;;
    *)
      echo "what is '${BUILD_HOST_PACKAGE}' precious?"
      exit 1 ;;
  esac
}

use_local_component_builds
setup_host_to_build

bundle install --path ../vendor

PROJECTS=($(find ./configs/projects -type f -exec basename {} .rb \; | sort | grep -v -E "${SKIP_PROJECTS_RE}" | grep -E "${INCLUDE_PROJECTS_RE}"))
for project in "${PROJECTS[@]}" ; do
    build $project
done
