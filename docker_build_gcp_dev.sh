#도커 빌드
export PROJECT_ID=$(gcloud config list project --format "value(core.project)")
export IMAGE_REPO_NAME=refine-goods-name
export IMAGE_TAG=v0.1-gcp-dev
export IMAGE_URI=gcr.io/$PROJECT_ID/$IMAGE_REPO_NAME:$IMAGE_TAG

docker build -f Dockerfile.qlora.v1.2.gcp.dev -t $IMAGE_URI ./

# #푸시
# docker push $IMAGE_URI