# Pinned by digest so DLC tag republications don't silently invalidate the
# buildx layer cache or allow content-hash retags to absorb base-image drift.
# To bump: aws ecr describe-images --registry-id 763104351884 --region us-west-2 \
#   --repository-name pytorch-inference \
#   --image-ids imageTag=2.3.0-gpu-py311-cu121-ubuntu20.04-sagemaker \
#   --query 'imageDetails[0].imageDigest' --output text
FROM 763104351884.dkr.ecr.us-west-2.amazonaws.com/pytorch-inference@sha256:561adb434163a239e2f55247e8fff4ed7191bb2b74098f2a8a827ee2353384da

ENV CUDA_HOME=/usr/local/cuda
ENV TORCH_CUDA_ARCH_LIST="7.5+PTX"

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
    --extra-index-url https://data.pyg.org/whl/torch-2.3.0+cu121.html

# FORCE_ONLY_CUDA=1: fails loudly if nvcc unavailable, preventing silent CPU-only builds
RUN FORCE_ONLY_CUDA=1 pip install --no-cache-dir --no-build-isolation \
    --no-binary=:all: \
    torch_scatter==2.1.2 torch_sparse==0.6.18 torch_cluster==1.6.3 \
    --extra-index-url https://data.pyg.org/whl/torch-2.3.0+cu121.html

# Verify CUDA kernels are present by globbing for compiled _*_cuda*.so files
# (the canonical pattern PyG uses internally to discriminate CUDA vs CPU flavor).
# The previous _version_cuda import probe was wrong: _version_cuda is a substring
# in compiled .so filenames, not an importable Python submodule.
RUN <<'EOF' python
import os, glob
import torch_scatter, torch_sparse, torch_cluster
for pkg in (torch_scatter, torch_sparse, torch_cluster):
    d = os.path.dirname(pkg.__file__)
    assert glob.glob(os.path.join(d, '_*_cuda*.so')), f'CUDA build missing for {pkg.__name__}'
print('OK: native ops compiled with CUDA')
EOF

COPY inference.py /opt/ml/model/code/inference.py

ENV SAGEMAKER_PROGRAM=inference.py
