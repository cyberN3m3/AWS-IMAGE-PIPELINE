# Import libraries we need
import json          # Work with JSON data
import boto3         # Talk to AWS
import os            # Access environment variables
from PIL import Image     # Work with images
from io import BytesIO    # Work with data in memory
import logging            # Write log messages
from datetime import datetime  # Work with dates/times

# Set up logging (like a diary of what happens)
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Create connections to AWS services
s3_client = boto3.client('s3')      # Talk to S3 (storage)
sns_client = boto3.client('sns')    # Talk to SNS (notifications)

# Get configuration from environment
# (These will be set automatically by AWS)
PROCESSED_BUCKET = os.environ.get('PROCESSED_BUCKET')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN')

# Define image sizes we want to create
SIZES = {
    'thumbnail': (150, 150),    # Small preview
    'mobile': (480, 480),       # Phone size
    'web': (1024, 1024)         # Computer size
}

def lambda_handler(event, context):
    """
    This function runs when an image is uploaded
    
    event: Information about what triggered this
    context: AWS environment information
    """
    try:
        # Loop through all uploaded files
        # (Usually just 1, but could be multiple)
        for record in event['Records']:
            # Get information about the uploaded file
            bucket = record['s3']['bucket']['name']  # Which bucket
            key = record['s3']['object']['key']      # File name
            
            # Write a log message
            logger.info(f"Processing image: {key} from bucket: {bucket}")
            
            # Skip if this is already a processed image
            if 'processed/' in key:
                logger.info("Skipping already processed image")
                continue
            
            # Download the image from S3
            response = s3_client.get_object(Bucket=bucket, Key=key)
            image_content = response['Body'].read()
            
            # Process the image (resize it)
            results = process_image(image_content, key)
            
            # Send email notification
            send_notification(key, results)
            
            logger.info(f"Successfully processed {key}")
        
        # Return success message
        return {
            'statusCode': 200,
            'body': json.dumps('Image processing completed successfully')
        }
        
    except Exception as e:
        # If something goes wrong, log the error
        logger.error(f"Error processing image: {str(e)}")
        raise e

def process_image(image_content, original_key):
    """
    Resize image to multiple sizes
    
    image_content: The actual image data (bytes)
    original_key: Original filename
    
    Returns: Dictionary with information about created images
    """
    results = {}
    
    try:
        # Open the image using PIL (Pillow)
        image = Image.open(BytesIO(image_content))
        
        # Get info about original image
        original_format = image.format  # JPG, PNG, etc.
        original_size = image.size      # Width x Height
        
        logger.info(f"Original image: {original_size}, Format: {original_format}")
        
        # Create each size variant
        for size_name, dimensions in SIZES.items():
            # Resize the image
            resized_image = resize_image(image, dimensions)
            
            # Convert to bytes for uploading
            buffer = BytesIO()
            resized_image.save(buffer, format='JPEG', quality=85, optimize=True)
            buffer.seek(0)  # Reset to beginning
            
            # Create filename for processed image
            processed_key = f"processed/{size_name}/{original_key}"
            
            # Upload to S3
            s3_client.put_object(
                Bucket=PROCESSED_BUCKET,
                Key=processed_key,
                Body=buffer,
                ContentType='image/jpeg',
                Metadata={
                    'original-size': f"{original_size[0]}x{original_size[1]}",
                    'processed-size': f"{resized_image.size[0]}x{resized_image.size[1]}",
                    'variant': size_name,
                    'processed-date': datetime.utcnow().isoformat()
                }
            )
            
            # Save results
            results[size_name] = {
                'size': resized_image.size,
                'key': processed_key
            }
            
            logger.info(f"Created {size_name} variant: {resized_image.size}")
        
        return results
        
    except Exception as e:
        logger.error(f"Error in process_image: {str(e)}")
        raise e

def resize_image(image, target_size):
    """
    Resize image while keeping aspect ratio
    
    image: PIL Image object
    target_size: Tuple like (150, 150)
    
    Returns: Resized PIL Image
    """
    # Convert RGBA/PNG to RGB/JPG if needed
    # (Some formats have transparency, JPG doesn't)
    if image.mode in ('RGBA', 'LA', 'P'):
        # Create white background
        background = Image.new('RGB', image.size, (255, 255, 255))
        # Paste image on white background
        background.paste(image, mask=image.split()[-1] if image.mode == 'RGBA' else None)
        image = background
    
    # Resize while maintaining aspect ratio
    # thumbnail() makes image fit within target_size
    image.thumbnail(target_size, Image.Resampling.LANCZOS)
    
    return image

def send_notification(image_key, results):
    """
    Send email notification via SNS
    
    image_key: Original filename
    results: Dictionary of created variants
    """
    try:
        # Build email message
        message = f"""
Image Processing Complete!

Original Image: {image_key}
Processed Variants:
"""
        # Add each variant to message
        for variant, info in results.items():
            message += f"  - {variant}: {info['size'][0]}x{info['size'][1]} -> {info['key']}\n"
        
        message += f"\nProcessed at: {datetime.utcnow().isoformat()}"
        
        # Send via SNS
        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"Image Processed: {image_key}",
            Message=message
        )
        
        logger.info("Notification sent successfully")
        
    except Exception as e:
        logger.error(f"Error sending notification: {str(e)}")
        # Don't crash if notification fails