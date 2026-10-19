//
// EyeDetection module for PocketPic Web
// Client-side face landmark and eye position detection using native Web APIs or lightweight canvas analysis algorithms.
//

const EyeDetection = {
  // Check if browser native FaceDetector API (Chromium / Shape Detection API) is available
  hasNativeFaceDetector: 'FaceDetector' in window,
  faceDetector: null,

  async init() {
    if (this.hasNativeFaceDetector && !this.faceDetector) {
      try {
        // Request landmark detection if supported
        this.faceDetector = new window.FaceDetector({ maxDetectedFaces: 1, fastMode: false });
      } catch (e) {
        console.warn('Native FaceDetector initialization error:', e);
        this.hasNativeFaceDetector = false;
      }
    }
  },

  async detectEyes(imageSource) {
    await this.init();

    // Convert source (blob, image, canvas, element) to ImageElement / Canvas
    const img = await this.loadImage(imageSource);
    if (!img) return null;

    const width = img.naturalWidth || img.width;
    const height = img.naturalHeight || img.height;

    // 1. Try Native FaceDetector API first
    if (this.hasNativeFaceDetector && this.faceDetector) {
      try {
        const faces = await this.faceDetector.detect(img);
        if (faces && faces.length > 0) {
          const face = faces[0];
          const landmarks = face.landmarks || [];
          const leftEyeLandmark = landmarks.find(l => l.type === 'eye' && l.location.x < face.boundingBox.x + face.boundingBox.width / 2) || landmarks.find(l => l.type === 'eye');
          const rightEyeLandmark = landmarks.find(l => l.type === 'eye' && l.location.x >= face.boundingBox.x + face.boundingBox.width / 2);

          if (leftEyeLandmark && rightEyeLandmark) {
            return {
              leftEye: { x: leftEyeLandmark.location.x, y: leftEyeLandmark.location.y },
              rightEye: { x: rightEyeLandmark.location.x, y: rightEyeLandmark.location.y },
              imageSize: { width, height }
            };
          }

          // If box exists but no explicit eye landmarks, estimate eyes from face bounding box
          if (face.boundingBox) {
            const box = face.boundingBox;
            const leftEye = {
              x: box.x + box.width * 0.3,
              y: box.y + box.height * 0.35
            };
            const rightEye = {
              x: box.x + box.width * 0.7,
              y: box.y + box.height * 0.35
            };
            return { leftEye, rightEye, imageSize: { width, height } };
          }
        }
      } catch (e) {
        console.warn('Native face detection failed, using fallback:', e);
      }
    }

    // 2. Client-side heuristic fallback detector (Luminance & contrast analysis in upper face region)
    return this.detectEyesFallback(img, width, height);
  },

  async detectEyesFallback(img, width, height) {
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(img, 0, 0, width, height);

    const imgData = ctx.getImageData(0, 0, width, height);
    const pixels = imgData.data;

    // Scan upper-middle region of photo (typical selfie framing)
    const startY = Math.floor(height * 0.15);
    const endY = Math.floor(height * 0.55);
    const startX = Math.floor(width * 0.15);
    const endX = Math.floor(width * 0.85);

    let minLuminanceLeft = 255;
    let minLuminanceRight = 255;
    let leftEye = { x: Math.floor(width * 0.35), y: Math.floor(height * 0.35) };
    let rightEye = { x: Math.floor(width * 0.65), y: Math.floor(height * 0.35) };

    const midX = Math.floor(width / 2);

    for (let y = startY; y < endY; y += 4) {
      for (let x = startX; x < endX; x += 4) {
        const idx = (y * width + x) * 4;
        const r = pixels[idx];
        const g = pixels[idx + 1];
        const b = pixels[idx + 2];
        const luminance = 0.299 * r + 0.587 * g + 0.114 * b;

        if (x < midX) {
          if (luminance < minLuminanceLeft) {
            minLuminanceLeft = luminance;
            leftEye = { x, y };
          }
        } else {
          if (luminance < minLuminanceRight) {
            minLuminanceRight = luminance;
            rightEye = { x, y };
          }
        }
      }
    }

    return {
      leftEye,
      rightEye,
      imageSize: { width, height }
    };
  },

  loadImage(source) {
    return new Promise((resolve, reject) => {
      if (source instanceof HTMLImageElement) {
        if (source.complete) resolve(source);
        else {
          source.onload = () => resolve(source);
          source.onerror = reject;
        }
        return;
      }

      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = reject;

      if (source instanceof Blob) {
        img.src = URL.createObjectURL(source);
      } else if (typeof source === 'string') {
        img.src = source;
      } else if (source instanceof HTMLCanvasElement || source instanceof HTMLVideoElement) {
        resolve(source);
      } else {
        reject(new Error('Invalid image source for eye detection'));
      }
    });
  }
};

window.EyeDetection = EyeDetection;
