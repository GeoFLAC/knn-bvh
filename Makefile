# Makefile for knn-bvh
#
# Targets:
#   make             — build static library (lib/libknn_bvh.{2,3}d.sm<cc>.a)
#   make shared      — build shared library (lib/libknn_bvh.{2,3}d.sm<cc>.so)
#   make examples    — build all example binaries in bin/
#   make clean
#
# Options (pass on command line):
#   NDIM=2           — 2-D point clouds (default: 3)
#   SM=86            — CUDA compute capability (default: auto-detect; names the artifact)
#   DEBUG=1          — disable optimisations, add -G
#   NVCC=nvcc        — path to nvcc
#   CXX=g++          — C++ compiler for .cpp examples (default g++; nvc++ when openacc=1)
#   openacc=1        — compile .cpp examples with nvc++ (-acc=gpu -cuda)

NVCC      ?= nvcc
CXX       ?= g++
# Detect SM from nvidia-smi (strips the dot: "8.0" -> "80"), else fall back to "80".
SM        ?= $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
                 | head -1 | tr -d '.')
ifeq ($(strip $(SM)),)
  SM := 80
  $(warning No GPU detected via nvidia-smi -- defaulting to SM=$(SM). Pass SM=<cc> to build for another arch.)
endif
NDIM      ?= 3
DEBUG     ?= 0
CUDA_HOME ?= $(dir $(shell which $(NVCC)))..
openacc   ?= 0

# Dimension suffix: "3d" or "2d"
DIMSUF = $(NDIM)d

# Artifact suffix: dimension plus GPU arch, e.g. "3d.sm80".
LIBSUF = $(DIMSUF).sm$(SM)

# When openacc=1: use nvc++ and NVHPC's bundled nvcc (mirrors DynEarthSol's Makefile)
ifeq ($(openacc), 1)
	CXX  = nvc++
	NVCC = nvcc
endif

# Directories
INCDIR  = include
SRCDIR  = src
LIBDIR  = lib
BINDIR  = bin
LBVHDIR = lbvh

# nvcc flags (shared by lib and .cu examples)
NVCCFLAGS = -std=c++14 -arch=sm_$(SM) \
            -I$(INCDIR) -I$(LBVHDIR) \
            --expt-relaxed-constexpr --extended-lambda \
            -MMD -MP

# g++ flags (used for .cpp examples in non-openacc mode)
CXXFLAGS  = -std=c++14 -I$(INCDIR) \
            -I$(CUDA_HOME)/include \
            -MMD -MP

ifeq ($(NDIM),2)
	NVCCFLAGS += -DKNN_2D
	CXXFLAGS  += -DKNN_2D
endif

ifeq ($(DEBUG),1)
	NVCCFLAGS += -O0 -G -lineinfo
	CXXFLAGS  += -O0 -g
else
	NVCCFLAGS += -O3
	CXXFLAGS  += -O2
endif

# CUDA runtime libraries (needed when linking .cpp with g++)
CUDA_LDFLAGS = -L$(CUDA_HOME)/lib64 -lcudart -lcuda

# Compile+link command for .cpp examples.
# openacc=1: nvc++ drives the link with -acc=gpu -cuda so it resolves CUDA
#            device code and enables managed memory (mirrors DynEarthSol).
# default:   nvcc -ccbin $(CXX) wrapper (no CUDA syntax needed in the source).
ifeq ($(openacc), 1)
	CPP_COMPILE = $(CXX) -std=c++14 -I$(INCDIR) -MMD -MP \
                  -acc=gpu -cuda -DACC -Minfo=accel \
                  -o $@ $< -L$(LIBDIR) -lknn_bvh.$(LIBSUF) \
                  -acc=gpu -cuda -gpu=mem:managed
else
	CPP_COMPILE = $(NVCC) -std=c++14 -arch=sm_$(SM) -I$(INCDIR) -MMD -MP \
                  -ccbin $(CXX) -x c++ \
                  -o $@ $< -L$(LIBDIR) -lknn_bvh.$(LIBSUF)
endif

# ---------------------------------------------------------------------------
# Library & Targets
# ---------------------------------------------------------------------------
LIB_SRC   = $(SRCDIR)/knn_bvh.cu
LIB_OBJ   = $(LIBDIR)/knn_bvh.$(LIBSUF).o
LIB_DLINK = $(LIBDIR)/knn_bvh.$(LIBSUF)_dlink.o
LIB_A     = $(LIBDIR)/libknn_bvh.$(LIBSUF).a
LIB_SO    = $(LIBDIR)/libknn_bvh.$(LIBSUF).so

CU_SRCS  = $(wildcard examples/*.cu)
CPP_SRCS = $(wildcard examples/*.cpp)
CU_BINS  = $(patsubst examples/%.cu, $(BINDIR)/%.$(DIMSUF), $(CU_SRCS))
CPP_BINS = $(patsubst examples/%.cpp,$(BINDIR)/%.$(DIMSUF), $(CPP_SRCS))

DEPS = $(LIBDIR)/knn_bvh.$(LIBSUF).d \
       $(LIBDIR)/libknn_bvh.$(LIBSUF).d \
       $(CU_BINS:%=%.d) \
       $(CPP_BINS:%=%.d)

PATCH_FILE = lbvh_fix.patch

.PHONY: all shared examples clean prepare build_static build_shared build_examples

all: prepare
	$(MAKE) build_static

shared: prepare
	$(MAKE) build_shared

examples: prepare
	$(MAKE) build_examples

# ---------------------------------------------------------------------------
# Stage 1: Prepare (Submodule & Patches)
# ---------------------------------------------------------------------------
prepare:
# Check and update lbvh submodule
	@if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
		if git submodule status $(LBVHDIR) | grep -q '^[-+]'; then \
			echo "Submodule $(LBVHDIR) status mismatch. Updating submodule $(LBVHDIR)..."; \
			git submodule update --init --recursive --force $(LBVHDIR); \
		fi; \
	elif [ -f "$(LBVHDIR)/lbvh/bvh.cuh" ]; then \
		:; \
	else \
		echo "Error: LBVHDIR $(LBVHDIR) is missing or empty. Git is unavailable or this is not a git repo."; \
		exit 1; \
	fi

# Check and apply patch to lbvh if not already applied
	@if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then \
		if !(cd $(LBVHDIR) && git apply --reverse --check ../$(PATCH_FILE) >/dev/null 2>&1); then \
			echo "Applying $(PATCH_FILE) to $(LBVHDIR) via git..."; \
			(cd $(LBVHDIR) && git apply ../$(PATCH_FILE) && git update-index --skip-worktree lbvh/bvh.cuh); \
		fi; \
	else \
		if command -v patch >/dev/null 2>&1; then \
			if !(cd $(LBVHDIR) && patch -R -p1 --dry-run < ../$(PATCH_FILE) >/dev/null 2>&1); then \
				echo "Applying $(PATCH_FILE) to $(LBVHDIR) via standard patch..."; \
				(cd $(LBVHDIR) && patch -N -p1 < ../$(PATCH_FILE) >/dev/null); \
			fi; \
		else \
			echo "Warning: Both 'git' and 'patch' are unavailable. Cannot verify or apply $(PATCH_FILE)."; \
		fi; \
	fi
# to unmask: git update-index --no-skip-worktree lbvh/bvh.cuh 

# ---------------------------------------------------------------------------
# Stage 2: Actual Build Rules
# ---------------------------------------------------------------------------
build_static: $(LIB_A)
build_shared: $(LIB_SO)
build_examples: $(CU_BINS) $(CPP_BINS)

# Relocatable device-code object
$(LIB_OBJ): $(LIB_SRC) | $(LIBDIR)
	$(NVCC) $(NVCCFLAGS) -dc -o $@ $<

# Device-link stub
$(LIB_DLINK): $(LIB_OBJ) | $(LIBDIR)
	$(NVCC) -dlink -arch=sm_$(SM) -o $@ $<

# Static library
$(LIB_A): $(LIB_OBJ) $(LIB_DLINK) | $(LIBDIR)
	ar rcs $@ $^
	@echo "Built static library: $@"

# Shared library
$(LIB_SO): $(LIB_SRC) | $(LIBDIR)
	$(NVCC) $(NVCCFLAGS) --shared -Xcompiler -fPIC -o $@ $<
	@echo "Built shared library: $@"

# .cu examples
$(BINDIR)/%.$(DIMSUF): examples/%.cu $(LIB_A) | $(BINDIR)
	$(NVCC) $(NVCCFLAGS) -o $@ $< -L$(LIBDIR) -lknn_bvh.$(LIBSUF) -lcuda
	@echo "Built example: $@"

# .cpp examples
$(BINDIR)/%.$(DIMSUF): examples/%.cpp $(LIB_A) | $(BINDIR)
	$(CPP_COMPILE)
	@echo "Built example: $@"

$(LIBDIR) $(BINDIR):
	mkdir -p $@

clean:
	rm -f $(LIBDIR)/*.$(DIMSUF)* $(CU_BINS) $(CPP_BINS) $(DEPS)
	@rmdir --ignore-fail-on-non-empty $(LIBDIR) $(BINDIR) 2>/dev/null; true

# Dependencies Inclusion
-include $(DEPS)