const CONFIG = {
    region: 'us-east-1',
    sourceBucket: 'image-pipeline-source-dev-440209552762',  
    processedBucket: 'image-pipeline-processed-dev-440209552762',  
    identityPoolId: 'INPUT IDENTITY POOL ID '  
};

// Configure AWS SDK
AWS.config.region = CONFIG.region;
AWS.config.credentials = new AWS.CognitoIdentityCredentials({
    IdentityPoolId: CONFIG.identityPoolId
});

const s3 = new AWS.S3();

// ============================================
// GLOBAL STATE
// ============================================

let uploadedFiles = [];
let processingFiles = new Set();

// ============================================
// UPLOAD FUNCTIONALITY
// ============================================

const uploadArea = document.getElementById('uploadArea');
const fileInput = document.getElementById('fileInput');

// Drag and drop handlers
uploadArea.addEventListener('dragover', (e) => {
    e.preventDefault();
    uploadArea.classList.add('dragover');
});

uploadArea.addEventListener('dragleave', () => {
    uploadArea.classList.remove('dragover');
});

uploadArea.addEventListener('drop', (e) => {
    e.preventDefault();
    uploadArea.classList.remove('dragover');
    
    const files = e.dataTransfer.files;
    handleFiles(files);
});

// Click to upload
uploadArea.addEventListener('click', (e) => {
    if (e.target !== fileInput) {
        fileInput.click();
    }
});

fileInput.addEventListener('change', (e) => {
    handleFiles(e.target.files);
});

// ============================================
// FILE HANDLING
// ============================================

function handleFiles(files) {
    const imageFiles = Array.from(files).filter(file => 
        file.type.startsWith('image/')
    );
    
    if (imageFiles.length === 0) {
        alert('Please select image files only!');
        return;
    }
    
    if (imageFiles.length > 10) {
        alert('Maximum 10 images at a time!');
        return;
    }
    
    uploadFiles(imageFiles);
}

async function uploadFiles(files) {
    document.getElementById('uploadProgress').style.display = 'block';
    document.getElementById('uploadQueue').innerHTML = '';
    
    let completed = 0;
    const total = files.length;
    
    for (const file of files) {
        try {
            // Show file in queue
            addToQueue(file.name, 'uploading');
            
            // Upload to S3
            await uploadToS3(file);
            
            // Update queue
            updateQueue(file.name, 'processing');
            
            // Add to processing list
            processingFiles.add(file.name);
            uploadedFiles.push(file.name);
            
            // Update progress
            completed++;
            const percentage = Math.round((completed / total) * 100);
            updateProgress(percentage, `Uploaded ${completed}/${total} files`);
            
        } catch (error) {
            console.error('Upload error:', error);
            updateQueue(file.name, 'error');
            alert(`Failed to upload ${file.name}: ${error.message}`);
        }
    }
    
    // Start checking for processed images
    setTimeout(() => {
        document.getElementById('uploadProgress').style.display = 'none';
        checkProcessedImages();
    }, 2000);
}

function uploadToS3(file) {
    return new Promise((resolve, reject) => {
        const params = {
            Bucket: CONFIG.sourceBucket,
            Key: file.name,
            Body: file,
            ContentType: file.type
        };
        
        s3.upload(params, (err, data) => {
            if (err) {
                reject(err);
            } else {
                resolve(data);
            }
        });
    });
}

function updateProgress(percentage, status) {
    const progressBar = document.getElementById('progressBar');
    progressBar.style.width = percentage + '%';
    progressBar.textContent = percentage + '%';
    document.getElementById('uploadStatus').textContent = status;
}

function addToQueue(filename, status) {
    const queueDiv = document.getElementById('uploadQueue');
    const fileDiv = document.createElement('div');
    fileDiv.id = `queue-${filename}`;
    fileDiv.className = 'alert alert-info';
    fileDiv.innerHTML = `
        <i class="fas fa-file-image"></i> ${filename} 
        <span class="badge bg-primary float-end">${status}</span>
    `;
    queueDiv.appendChild(fileDiv);
}

function updateQueue(filename, status) {
    const fileDiv = document.getElementById(`queue-${filename}`);
    if (fileDiv) {
        const badge = fileDiv.querySelector('.badge');
        badge.textContent = status;
        
        if (status === 'processing') {
            fileDiv.className = 'alert alert-warning';
            badge.className = 'badge bg-warning float-end';
        } else if (status === 'complete') {
            fileDiv.className = 'alert alert-success';
            badge.className = 'badge bg-success float-end';
        } else if (status === 'error') {
            fileDiv.className = 'alert alert-danger';
            badge.className = 'badge bg-danger float-end';
        }
    }
}

// ============================================
// CHECK FOR PROCESSED IMAGES
// ============================================

async function checkProcessedImages() {
    const variants = ['thumbnail', 'mobile', 'web'];
    
    for (const filename of uploadedFiles) {
        let allVariantsReady = true;
        
        for (const variant of variants) {
            const key = `processed/${variant}/${filename}`;
            
            try {
                await s3.headObject({
                    Bucket: CONFIG.processedBucket,
                    Key: key
                }).promise();
                
                // File exists, display it
                displayProcessedImage(filename, variant);
                
            } catch (error) {
                // File doesn't exist yet
                allVariantsReady = false;
            }
        }
        
        if (allVariantsReady) {
            processingFiles.delete(filename);
            updateQueue(filename, 'complete');
        }
    }
    
    // Show results section
    document.getElementById('resultsSection').style.display = 'block';
    
    // Keep checking if files are still processing
    if (processingFiles.size > 0) {
        setTimeout(checkProcessedImages, 3000);  // Check every 3 seconds
    }
}

function displayProcessedImage(filename, variant) {
    const containerId = `${variant}Images`;
    const container = document.getElementById(containerId);
    
    // Check if already displayed
    if (document.getElementById(`${variant}-${filename}`)) {
        return;
    }
    
    const imageUrl = s3.getSignedUrl('getObject', {
        Bucket: CONFIG.processedBucket,
        Key: `processed/${variant}/${filename}`,
        Expires: 3600  // URL valid for 1 hour
    });
    
    const imageDiv = document.createElement('div');
    imageDiv.id = `${variant}-${filename}`;
    imageDiv.className = 'image-preview';
    imageDiv.innerHTML = `
        <img src="${imageUrl}" alt="${filename}">
        <button class="download-btn" onclick="downloadImage('${variant}', '${filename}')" 
                title="Download">
            <i class="fas fa-download"></i>
        </button>
        <div class="status-badge status-complete">
            <i class="fas fa-check"></i> Ready
        </div>
    `;
    
    container.appendChild(imageDiv);
}

// ============================================
// DOWNLOAD FUNCTIONALITY
// ============================================

function downloadImage(variant, filename) {
    const url = s3.getSignedUrl('getObject', {
        Bucket: CONFIG.processedBucket,
        Key: `processed/${variant}/${filename}`,
        Expires: 60
    });
    
    const link = document.createElement('a');
    link.href = url;
    link.download = `${variant}-${filename}`;
    link.click();
}

function downloadAll() {
    const variants = ['thumbnail', 'mobile', 'web'];
    
    uploadedFiles.forEach(filename => {
        variants.forEach(variant => {
            setTimeout(() => downloadImage(variant, filename), 500);
        });
    });
}

// ============================================
// INITIALIZATION
// ============================================

document.addEventListener('DOMContentLoaded', () => {
    console.log('Image Resizer App Loaded');
    console.log('AWS SDK Version:', AWS.VERSION);
    
    // Check AWS credentials
    AWS.config.credentials.get((err) => {
        if (err) {
            console.error('Error getting AWS credentials:', err);
            alert('Error: Unable to authenticate with AWS. Please check configuration.');
        } else {
            console.log('AWS credentials loaded successfully');
        }
    });
});