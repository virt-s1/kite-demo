#/bin/bash
set -x
ver=$1
vendor_tarball=$2
cargo vendor
# Various vendor cleanups
pushd vendor
# cleanup windows files
rm -rf winapi/src/*
touch winapi/src/lib.rs
rm -rf winapi-x86_64-pc-windows-gnu/lib/*
rm -rf winapi-i686-pc-windows-gnu/lib/*
rm -rf vcpkg/test-data
popd #vendor
tar cjf $vendor_tarball vendor/
