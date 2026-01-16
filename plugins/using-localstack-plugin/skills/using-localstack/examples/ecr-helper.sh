#!/bin/bash
# ECR Image Management Helper Script
# Provides utilities for managing container images in LocalStack ECR

set -e

# Configuration
ECR_ENDPOINT="localhost:4566"
ECR_DOMAIN="localhost.localstack.cloud:4566"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[ECR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create repository
create_repo() {
    local repo_name=$1
    
    if [ -z "$repo_name" ]; then
        error "Repository name required"
        echo "Usage: $0 create <repository-name>"
        exit 1
    fi
    
    log "Creating repository: $repo_name"
    awslocal ecr create-repository \
        --repository-name "$repo_name" \
        --image-scanning-configuration scanOnPush=true \
        --region "$AWS_REGION"
    
    log "Repository created successfully"
}

# List repositories
list_repos() {
    log "Listing ECR repositories"
    awslocal ecr describe-repositories \
        --region "$AWS_REGION" \
        --query 'repositories[].{Name:repositoryName,URI:repositoryUri,CreatedAt:createdAt}' \
        --output table
}

# List images in repository
list_images() {
    local repo_name=$1
    
    if [ -z "$repo_name" ]; then
        error "Repository name required"
        echo "Usage: $0 list-images <repository-name>"
        exit 1
    fi
    
    log "Listing images in repository: $repo_name"
    awslocal ecr describe-images \
        --repository-name "$repo_name" \
        --region "$AWS_REGION" \
        --query 'imageDetails[].{Tags:imageTags[0],Digest:imageDigest,Size:imageSizeInBytes,PushedAt:imagePushedAt}' \
        --output table
}

# Login to ECR
ecr_login() {
    log "Authenticating with LocalStack ECR"
    awslocal ecr get-login-password --region "$AWS_REGION" | \
        docker login --username AWS --password-stdin "$ECR_ENDPOINT"
    
    log "Login successful"
}

# Build, tag, and push image
build_push() {
    local dockerfile_path=$1
    local repo_name=$2
    local tag=${3:-latest}
    
    if [ -z "$dockerfile_path" ] || [ -z "$repo_name" ]; then
        error "Missing required arguments"
        echo "Usage: $0 build-push <dockerfile-path> <repository-name> [tag]"
        exit 1
    fi
    
    local image_name="${repo_name}:${tag}"
    local ecr_image="${ECR_DOMAIN}/${image_name}"
    
    log "Building image: $image_name"
    docker build -t "$image_name" "$dockerfile_path"
    
    log "Tagging image for ECR: $ecr_image"
    docker tag "$image_name" "$ecr_image"
    
    log "Logging in to ECR"
    ecr_login
    
    log "Pushing image: $ecr_image"
    docker push "$ecr_image"
    
    log "Image pushed successfully"
    echo ""
    echo "Image URI: ${ECR_DOMAIN}/${repo_name}:${tag}"
}

# Pull image from ECR
pull_image() {
    local repo_name=$1
    local tag=${2:-latest}
    
    if [ -z "$repo_name" ]; then
        error "Repository name required"
        echo "Usage: $0 pull <repository-name> [tag]"
        exit 1
    fi
    
    local ecr_image="${ECR_DOMAIN}/${repo_name}:${tag}"
    
    log "Logging in to ECR"
    ecr_login
    
    log "Pulling image: $ecr_image"
    docker pull "$ecr_image"
    
    log "Image pulled successfully"
}

# Delete image
delete_image() {
    local repo_name=$1
    local tag=$2
    
    if [ -z "$repo_name" ] || [ -z "$tag" ]; then
        error "Missing required arguments"
        echo "Usage: $0 delete-image <repository-name> <tag>"
        exit 1
    fi
    
    log "Deleting image: ${repo_name}:${tag}"
    awslocal ecr batch-delete-image \
        --repository-name "$repo_name" \
        --image-ids imageTag="$tag" \
        --region "$AWS_REGION"
    
    log "Image deleted successfully"
}

# Delete repository
delete_repo() {
    local repo_name=$1
    local force=${2:-false}
    
    if [ -z "$repo_name" ]; then
        error "Repository name required"
        echo "Usage: $0 delete-repo <repository-name> [force]"
        exit 1
    fi
    
    local force_flag=""
    if [ "$force" = "true" ]; then
        force_flag="--force"
        warn "Force deleting repository (all images will be deleted)"
    fi
    
    log "Deleting repository: $repo_name"
    awslocal ecr delete-repository \
        --repository-name "$repo_name" \
        --region "$AWS_REGION" \
        $force_flag
    
    log "Repository deleted successfully"
}

# Get repository URI
get_uri() {
    local repo_name=$1
    
    if [ -z "$repo_name" ]; then
        error "Repository name required"
        echo "Usage: $0 get-uri <repository-name>"
        exit 1
    fi
    
    awslocal ecr describe-repositories \
        --repository-names "$repo_name" \
        --region "$AWS_REGION" \
        --query 'repositories[0].repositoryUri' \
        --output text
}

# Main command dispatcher
case "${1:-help}" in
    create)
        create_repo "$2"
        ;;
    list)
        list_repos
        ;;
    list-images)
        list_images "$2"
        ;;
    login)
        ecr_login
        ;;
    build-push)
        build_push "$2" "$3" "$4"
        ;;
    pull)
        pull_image "$2" "$3"
        ;;
    delete-image)
        delete_image "$2" "$3"
        ;;
    delete-repo)
        delete_repo "$2" "$3"
        ;;
    get-uri)
        get_uri "$2"
        ;;
    help|*)
        echo "LocalStack ECR Management Tool"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  create <name>                    Create ECR repository"
        echo "  list                             List all repositories"
        echo "  list-images <name>               List images in repository"
        echo "  login                            Authenticate with ECR"
        echo "  build-push <path> <name> [tag]   Build and push image"
        echo "  pull <name> [tag]                Pull image from ECR"
        echo "  delete-image <name> <tag>        Delete specific image"
        echo "  delete-repo <name> [force]       Delete repository"
        echo "  get-uri <name>                   Get repository URI"
        echo "  help                             Show this help"
        echo ""
        echo "Examples:"
        echo "  $0 create lambda-processor"
        echo "  $0 build-push ./my-app lambda-processor v1.0.0"
        echo "  $0 list-images lambda-processor"
        echo "  $0 delete-repo lambda-processor true"
        ;;
esac
