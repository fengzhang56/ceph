#!/usr/bin/env bash
# -*- mode:sh; tab-width:8; indent-tabs-mode:t -*-
#
# Ceph distributed storage system
#
# Copyright (C) 2014, 2015 Red Hat <contact@redhat.com>
#
# Author: Loic Dachary <loic@dachary.org>
#
#  This library is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public
#  License as published by the Free Software Foundation; either
#  version 2.1 of the License, or (at your option) any later version.
#
set -e
DIR=/tmp/install-deps.$$
trap "rm -fr $DIR" EXIT
mkdir -p $DIR
if test $(id -u) != 0 ; then
    SUDO=sudo
fi
export LC_ALL=C # the following is vulnerable to i18n

ARCH=`uname -m`

function munge_ceph_spec_in {
    # http://rpm.org/user_doc/conditional_builds.html
    local OUTFILE=$1
    sed -e 's/@//g' -e 's/%bcond_with make_check/%bcond_without make_check/g' < ceph.spec.in > $OUTFILE
}

function ensure_decent_gcc_on_ubuntu {
    # point gcc to the one offered by g++-7 if the used one is not
    # new enough
    local old=$(gcc -dumpversion)
    local new=$1
    local codename=$2
    if dpkg --compare-versions $old ge 7.0; then
	return
    fi

    if [ ! -f /usr/bin/g++-${new} ]; then
	$SUDO tee /etc/apt/sources.list.d/ubuntu-toolchain-r.list <<EOF
deb http://ppa.launchpad.net/ubuntu-toolchain-r/test/ubuntu $codename main
deb [arch=amd64] http://mirror.cs.uchicago.edu/ubuntu-toolchain-r $codename main
deb [arch=amd64,i386] http://mirror.yandex.ru/mirrors/launchpad/ubuntu-toolchain-r $codename main
EOF
	# import PPA's signing key into APT's keyring
	$SUDO apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 1E9377A2BA9EF27F
	$SUDO apt-get -y update -o Acquire::Languages=none -o Acquire::Translation=none || true
	$SUDO apt-get install -y g++-7
    fi

    case $codename in
        trusty)
            old=4.8;;
        xenial)
            old=5;;
    esac
    $SUDO update-alternatives --remove-all gcc || true
    $SUDO update-alternatives \
	 --install /usr/bin/gcc gcc /usr/bin/gcc-${new} 20 \
	 --slave   /usr/bin/g++ g++ /usr/bin/g++-${new}

    $SUDO update-alternatives \
	 --install /usr/bin/gcc gcc /usr/bin/gcc-${old} 10 \
	 --slave   /usr/bin/g++ g++ /usr/bin/g++-${old}

    $SUDO update-alternatives --auto gcc

    # cmake uses the latter by default
    $SUDO ln -nsf /usr/bin/gcc /usr/bin/x86_64-linux-gnu-gcc
    $SUDO ln -nsf /usr/bin/g++ /usr/bin/x86_64-linux-gnu-g++
}

function version_lt {
    test $1 != $(echo -e "$1\n$2" | sort -rV | head -n 1)
}

function ensure_decent_gcc_on_rh {
    local old=$(gcc -dumpversion)
    local expected=5.1
    local dts_ver=$1
    if version_lt $old $expected; then
	if test -t 1; then
	    # interactive shell
	    cat <<EOF
Your GCC is too old. Please run following command to add DTS to your environment:

scl enable devtoolset-7 bash

Or add following line to the end of ~/.bashrc to add it permanently:

source scl_source enable devtoolset-7

see https://www.softwarecollections.org/en/scls/rhscl/devtoolset-7/ for more details.
EOF
	else
	    # non-interactive shell
	    source /opt/rh/devtoolset-$dts_ver/enable
	fi
    fi
}

if [ x`uname`x = xFreeBSDx ]; then
    $SUDO pkg install -yq \
        devel/babeltrace \
        devel/git \
        devel/gperf \
        devel/gmake \
        devel/cmake \
        devel/yasm \
        devel/boost-all \
        devel/boost-python-libs \
        devel/valgrind \
        devel/pkgconf \
        devel/libedit \
        devel/libtool \
        devel/google-perftools \
        lang/cython \
        devel/py-virtualenv \
        databases/leveldb \
        net/openldap-client \
        security/nss \
        archivers/snappy \
        archivers/liblz4 \
        ftp/curl \
        misc/e2fsprogs-libuuid \
        misc/getopt \
        net/socat \
        textproc/expat2 \
        textproc/gsed \
        lang/gawk \
        textproc/libxml2 \
        textproc/xmlstarlet \
        textproc/jq \
        textproc/py-sphinx \
        emulators/fuse \
        java/junit \
        lang/python \
        lang/python27 \
        devel/py-pip \
        devel/py-argparse \
        devel/py-nose \
        devel/py-prettytable \
	www/py-routes \
        www/py-flask \
        www/fcgi \
	security/oath-toolkit \
        sysutils/flock \
        sysutils/fusefs-libs \

	# Now use pip to install some extra python modules
	pip install pecan

    exit
else
    source /etc/os-release
    case $ID in
    debian|ubuntu|devuan)
        echo "Using apt-get to install dependencies"
        $SUDO apt-get install -y devscripts equivs
        $SUDO apt-get install -y dpkg-dev
        case "$VERSION" in
            *Trusty*)
                ensure_decent_gcc_on_ubuntu 7 trusty
                ;;
            *Xenial*)
                ensure_decent_gcc_on_ubuntu 7 xenial
                ;;
            *)
                $SUDO apt-get install -y gcc
                ;;
        esac
        if ! test -r debian/control ; then
            echo debian/control is not a readable file
            exit 1
        fi
        touch $DIR/status

	backports=""
	control="debian/control"
        case "$VERSION" in
            *squeeze*|*wheezy*)
		control="/tmp/control.$$"
		grep -v babeltrace debian/control > $control
                backports="-t $codename-backports"
                ;;
        esac

	# make a metapackage that expresses the build dependencies,
	# install it, rm the .deb; then uninstall the package as its
	# work is done
	$SUDO env DEBIAN_FRONTEND=noninteractive mk-build-deps --install --remove --tool="apt-get -y --no-install-recommends $backports" $control || exit 1
	$SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y remove ceph-build-deps
	if [ -n "$backports" ] ; then rm $control; fi
        ;;
    centos|fedora|rhel|ol|virtuozzo)
        yumdnf="yum"
        builddepcmd="yum-builddep -y"
        if test "$(echo "$VERSION_ID >= 22" | bc)" -ne 0; then
            yumdnf="dnf"
            builddepcmd="dnf -y builddep --allowerasing"
        fi
        echo "Using $yumdnf to install dependencies"
	if [ "$ID" = "centos" -a $(uname -m) = aarch64 ]; then
	    $SUDO yum-config-manager --disable centos-sclo-sclo || true
	    $SUDO yum-config-manager --disable centos-sclo-rh || true
	    $SUDO yum remove centos-release-scl || true
	fi
        case $ID in
            fedora)
                if test $yumdnf = yum; then
                    $SUDO $yumdnf install -y yum-utils
                fi
                ;;
            centos|rhel|ol|virtuozzo)
                $SUDO yum install -y yum-utils
                if test $ID = rhel ; then
                    $SUDO yum-config-manager --enable rhel-$VERSION_ID-server-optional-rpms
                fi
                $SUDO yum-config-manager --add-repo https://dl.fedoraproject.org/pub/epel/$VERSION_ID/x86_64/
                $SUDO yum install --nogpgcheck -y epel-release
                $SUDO rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-$VERSION_ID
                $SUDO rm -f /etc/yum.repos.d/dl.fedoraproject.org*
                if test $ID = centos -a $VERSION_ID = 7 ; then
                    $SUDO yum-config-manager --enable cr
		    case $(uname -m) in
			x86_64)
			    $SUDO yum -y install centos-release-scl
			    dts_ver=7
			    ;;
			aarch64)
			    $SUDO yum -y install centos-release-scl-rh
			    $SUDO yum-config-manager --disable centos-sclo-rh
			    $SUDO yum-config-manager --enable centos-sclo-rh-testing
			    dts_ver=7
			    ;;
		    esac
                elif test $ID = rhel -a $MAJOR_VERSION = 7 ; then
                    $SUDO yum-config-manager --enable rhel-server-rhscl-7-rpms
                    dts_ver=7
                elif test $ID = virtuozzo -a $MAJOR_VERSION = 7 ; then
                    $SUDO yum-config-manager --enable cr
                fi
                ;;
        esac
        munge_ceph_spec_in $DIR/ceph.spec
        $SUDO $builddepcmd $DIR/ceph.spec 2>&1 | tee $DIR/yum-builddep.out
	if [ -n "$dts_ver" ]; then
            ensure_decent_gcc_on_rh $dts_ver
	fi
        ! grep -q -i error: $DIR/yum-builddep.out || exit 1
        ;;
    opensuse*|suse|sles)
        echo "Using zypper to install dependencies"
        zypp_install="zypper --gpg-auto-import-keys --non-interactive install --no-recommends"
        $SUDO $zypp_install systemd-rpm-macros
        munge_ceph_spec_in $DIR/ceph.spec
        $SUDO $zypp_install $(rpmspec -q --buildrequires $DIR/ceph.spec) || exit 1
        ;;
    alpine)
        # for now we need the testing repo for leveldb
        TESTREPO="http://nl.alpinelinux.org/alpine/edge/testing"
        if ! grep -qF "$TESTREPO" /etc/apk/repositories ; then
            $SUDO echo "$TESTREPO" | sudo tee -a /etc/apk/repositories > /dev/null
        fi
        source alpine/APKBUILD.in
        $SUDO apk --update add abuild build-base ccache $makedepends
        if id -u build >/dev/null 2>&1 ; then
           $SUDO addgroup build abuild
        fi
        ;;
    *)
        echo "$ID is unknown, dependencies will have to be installed manually."
	exit 1
        ;;
    esac
fi

function populate_wheelhouse() {
    local install=$1
    shift

    # although pip comes with virtualenv, having a recent version
    # of pip matters when it comes to using wheel packages
    # workaround of https://github.com/pypa/setuptools/issues/1042
    pip --timeout 300 $install 'setuptools >= 0.8,< 36' 'pip >= 7.0' 'wheel >= 0.24' || return 1
    if test $# != 0 ; then
        pip --timeout 300 $install $@ || return 1
    fi
}

function activate_virtualenv() {
    local top_srcdir=$1
    local interpreter=$2
    local env_dir=$top_srcdir/install-deps-$interpreter

    if ! test -d $env_dir ; then
        # Make a temporary virtualenv to get a fresh version of virtualenv
        # because CentOS 7 has a buggy old version (v1.10.1)
        # https://github.com/pypa/virtualenv/issues/463
        virtualenv ${env_dir}_tmp
        ${env_dir}_tmp/bin/pip install --upgrade virtualenv
        ${env_dir}_tmp/bin/virtualenv --python $interpreter $env_dir
        rm -rf ${env_dir}_tmp

        . $env_dir/bin/activate
        if ! populate_wheelhouse install ; then
            rm -rf $env_dir
            return 1
        fi
    fi
    . $env_dir/bin/activate
}

# use pip cache if possible but do not store it outside of the source
# tree
# see https://pip.pypa.io/en/stable/reference/pip_install.html#caching
mkdir -p install-deps-cache
top_srcdir=$(pwd)
export XDG_CACHE_HOME=$top_srcdir/install-deps-cache
wip_wheelhouse=wheelhouse-wip

#
# preload python modules so that tox can run without network access
#
find . -name tox.ini | while read ini ; do
    (
        cd $(dirname $ini)
        require=$(ls *requirements.txt 2>/dev/null | sed -e 's/^/-r /')
        if test "$require" && ! test -d wheelhouse ; then
            for interpreter in python2.7 python3 ; do
                type $interpreter > /dev/null 2>&1 || continue
                activate_virtualenv $top_srcdir $interpreter || exit 1
                populate_wheelhouse "wheel -w $wip_wheelhouse" $require || exit 1
            done
            mv $wip_wheelhouse wheelhouse
        fi
    )
done

for interpreter in python2.7 python3 ; do
    rm -rf $top_srcdir/install-deps-$interpreter
done
rm -rf $XDG_CACHE_HOME
