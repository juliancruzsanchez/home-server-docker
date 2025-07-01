# Use a base image with Python and CUDA (optional GPU support)
# Choose a suitable base image based on your needs.
# For CPU-only:  python:3.11-slim-bookworm
# For GPU support (Nvidia CUDA):  nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04  (or a more recent version)
FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

# Set working directory
WORKDIR /app

# Copy the Automatic1111 source code
# You can clone it directly into the container or copy a local directory
# Option 1: Clone from GitHub
RUN apt-get update && apt-get install -y git libgl1 libglib2.0-0 google-perftools
RUN git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git .

# Option 2:  If you already have the code locally (e.g., /path/to/stable-diffusion-webui)
# COPY stable-diffusion-webui .

# Install dependencies (using Automatic1111's requirements.txt)
RUN apt-get install -y --no-install-recommends python3 python3-pip python3.10-venv
RUN pip3 install -r requirements.txt

# Set environment variables (optional, but recommended)
ENV NVIDIA_VISIBLE_DEVICES all
ENV PYTHONUNBUFFERED 1

# Expose the port the Web UI runs on
EXPOSE 7860

RUN python3 -m venv venv/

# Command to run the Web UI. You might need to adjust this.
CMD ["./webui.sh", "-f", "--api", "--listen", "--xformers"]
