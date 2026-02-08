#!/bin/bash

echo "🔨 Building Lambda deployment package..."

# Remove old builds
rm -rf package
rm -f lambda-deployment.zip

# Create fresh package directory
mkdir package

# Install Python libraries
echo "📦 Installing Python dependencies..."
pip install -r image-processor/requirements.txt -t package/

# Copy our Python code
echo "📄 Adding Lambda function..."
cp image-processor/lambda_function.py package/

# Create ZIP file
echo "🗜️  Creating ZIP file..."
cd package
zip -r ../lambda-deployment.zip .
cd ..

# Clean up
rm -rf package

echo "✅ Build complete! Created lambda-deployment.zip"
echo "📊 File size:"
ls -lh lambda-deployment.zip