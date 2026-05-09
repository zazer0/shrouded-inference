FROM 763104351884.dkr.ecr.us-west-2.amazonaws.com/pytorch-inference:2.3.0-cpu-py311-ubuntu20.04-sagemaker

RUN pip install \
    --extra-index-url https://data.pyg.org/whl/torch-2.3.0+cpu.html \
    torch-scatter \
    torch-sparse \
    torch-geometric

COPY inference.py /opt/ml/model/code/inference.py

ENV SAGEMAKER_PROGRAM=inference.py
