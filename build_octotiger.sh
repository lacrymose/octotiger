

set -x

source ~/scripts/sourceme.sh gperftools
source ~/scripts/sourceme.sh hwloc
source ~/scripts/sourceme.sh vc
source ~/scripts/sourceme.sh silo
source ~/scripts/sourceme.sh $1/hpx

rm -rf $1
mkdir $1
cd $1
rm CMakeCache.txt
rm -r CMakeFiles


cmake -DCMAKE_PREFIX_PATH="$HOME/local/$1/hpx" -DCMAKE_CXX_FLAGS="-DBOOST_USE_VALGRIND" \
      -DCMAKE_CXX_COMPILER=g++ -DOCTOTIGER_WITH_TESTS=OFF \
      -DCMAKE_C_COMPILER=gcc \
      -DCMAKE_CXX_FLAGS="-pg -DBOOST_USE_VALGRIND -L$HOME/local/boost/lib -march=native" \
      -DCMAKE_C_FLAGS="-L$HOME/local/boost/lib" \
      -DCMAKE_BUILD_TYPE=$1                                                                                                                            \
      -DCMAKE_INSTALL_PREFIX="$HOME/local/$1/octotiger"                                   \
<<<<<<< HEAD
      -DBOOST_ROOT=$HOME/local/boost \
      -DHDF5_ROOT=$HOME/local/hdf5 \
      -DSilo_DIR=$HOME/local/silo \
      -DOCTOTIGER_BUILD_TESTS=off \
      ..
=======
      -DSilo_LIBRARY=$HOME/local/silo/lib/libsiloh5.a -DSilo_INCLUDE_DIR=$HOME/local/silo/include/ -DBOOST_ROOT=$HOME/local/boost/ \
      -DHDF5_ROOT=$HOME/local/hdf5/ ..
>>>>>>> new_amrbnd


make -j VERBOSE=1
make test VERBOSE=1


