//
// EyeDetection module for PocketPic Web
// Face landmark detection with MediaPipe Face Landmarker (the web equivalent of the
// Vision request used by the iOS app). Returns the centroid of each eye contour in
// image pixels, or null when no face is found.
//

const FACE_MODEL_URL = 'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task';
const TASKS_VISION_VERSION = '1.0.1';
const TASKS_VISION_CDN = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${TASKS_VISION_VERSION}`;

// MediaPipe face-mesh eye contours (16 points each).
const LEFT_EYE_INDICES = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246];
const RIGHT_EYE_INDICES = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466];

const EyeDetection = {
  landmarkerPromise: null,

  async preload() {
    return this.loadLandmarker();
  },

  loadLandmarker() {
    if (this.landmarkerPromise) return this.landmarkerPromise;

    this.landmarkerPromise = (async () => {
      const { FaceLandmarker, FilesetResolver } = await import(`${TASKS_VISION_CDN}/vision_bundle.mjs`);
      const fileset = await FilesetResolver.forVisionTasks(`${TASKS_VISION_CDN}/wasm`);
      const options = {
        baseOptions: { modelAssetPath: FACE_MODEL_URL, delegate: 'GPU' },
        runningMode: 'IMAGE',
        numFaces: 1
      };

      try {
        return await FaceLandmarker.createFromOptions(fileset, options);
      } catch (e) {
        console.warn('GPU face landmarker unavailable, using CPU:', e);
        return FaceLandmarker.createFromOptions(fileset, {
          ...options,
          baseOptions: { modelAssetPath: FACE_MODEL_URL }
        });
      }
    })().catch((error) => {
      this.landmarkerPromise = null;
      throw error;
    });

    return this.landmarkerPromise;
  },

  async detectEyes(imageSource) {
    const img = await this.loadImage(imageSource);
    if (!img) return null;

    const width = img.naturalWidth || img.width;
    const height = img.naturalHeight || img.height;
    if (!width || !height) return null;

    const landmarker = await this.loadLandmarker();
    const result = landmarker.detect(img);
    const face = result?.faceLandmarks?.[0];
    if (!face || face.length === 0) return null;

    const leftEye = this.eyeCenter(face, LEFT_EYE_INDICES, width, height);
    const rightEye = this.eyeCenter(face, RIGHT_EYE_INDICES, width, height);
    if (!leftEye || !rightEye) return null;

    return { leftEye, rightEye, imageSize: { width, height } };
  },

  eyeCenter(landmarks, indices, width, height) {
    let sumX = 0;
    let sumY = 0;
    let count = 0;

    for (const index of indices) {
      const point = landmarks[index];
      if (!point) continue;
      sumX += point.x;
      sumY += point.y;
      count++;
    }

    if (count === 0) return null;
    return { x: (sumX / count) * width, y: (sumY / count) * height };
  },

  loadImage(source) {
    return new Promise((resolve) => {
      if (source instanceof HTMLImageElement) {
        if (source.complete && source.naturalWidth) {
          resolve(source);
          return;
        }
        source.onload = () => resolve(source);
        source.onerror = () => resolve(null);
        return;
      }

      const img = new Image();
      img.onload = () => {
        if (img.src.startsWith('blob:')) URL.revokeObjectURL(img.src);
        resolve(img);
      };
      img.onerror = () => {
        if (img.src.startsWith('blob:')) URL.revokeObjectURL(img.src);
        resolve(null);
      };

      if (source instanceof Blob) {
        img.src = URL.createObjectURL(source);
      } else if (typeof source === 'string') {
        img.src = source;
      } else if (source instanceof HTMLCanvasElement || source instanceof HTMLVideoElement) {
        resolve(source);
      } else {
        resolve(null);
      }
    });
  }
};

window.EyeDetection = EyeDetection;
