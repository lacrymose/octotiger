#!/bin/bash -e
set -x

if [ ! -d "Vc/" ]; then
    git clone https://github.com/VcDevel/Vc
else
    cd Vc
    git pull
    cd ..
fi

cd Vc
git checkout mkretz/datapar
cd ..

mkdir -p Vc/build
cd Vc/build
cmake -DCMAKE_INSTALL_PREFIX="$Vc_ROOT" -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=release ../
make -j2 VERBOSE=1 install
cd ../..
