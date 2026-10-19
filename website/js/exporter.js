//
// Exporter module for PocketPic Web
// Encodes photos into a time-lapse video with optional eye alignment and customizable FPS.
//

const Exporter = {
  isExporting: false,
  progressCallback: null,

  async exportVideo({ photos, fps = 10, alignEyes = true, progressCallback }) {
    if (!photos || photos.length === 0) {
      throw new Error('No photos to export');
    }

    this.isExporting = true;
    this.progressCallback = progressCallback;

    const reportProgress = (percent, statusMsg) => {
      if (this.progressCallback) {
        this.progressCallback(Math.min(Math.max(percent, 0), 1), statusMsg);
      }
    };

    reportProgress(0.02, 'Preparing photos…');

    // Sort photos chronologically (oldest first for time-lapse)
    const sortedPhotos = [...photos].sort((a, b) => new Date(a.date) - new Date(b.date));

    // Determine target canvas resolution (e.g. 1080x1920 or native)
    let videoWidth = 1080;
    let videoHeight = 1920;

    // Load first image to set canvas dimensions and reference eye positions
    const firstImg = await EyeDetection.loadImage(sortedPhotos[0].blob);
    if (firstImg.width && firstImg.height) {
      if (firstImg.width > firstImg.height) {
        videoWidth = 1920;
        videoHeight = 1080;
      }
    }

    const canvas = document.createElement('canvas');
    canvas.width = videoWidth;
    canvas.height = videoHeight;
    const ctx = canvas.getContext('2d');

    // 1. Detect eyes on reference photo if alignEyes is enabled
    let refEyes = null;
    if (alignEyes && window.EyeDetection) {
      reportProgress(0.05, 'Detecting reference eye alignment…');
      try {
        refEyes = await EyeDetection.detectEyes(firstImg);
      } catch (e) {
        console.warn('Reference eye detection failed:', e);
      }
    }

    // Prepare MediaRecorder on canvas stream
    const stream = canvas.captureStream(fps);
    let recorder;
    const chunks = [];

    // Select supported video mimeType
    const mimeTypes = [
      'video/mp4;codecs=h264',
      'video/mp4',
      'video/webm;codecs=vp9',
      'video/webm;codecs=vp8',
      'video/webm'
    ];
    let selectedMime = mimeTypes.find(type => MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(type)) || 'video/webm';

    try {
      recorder = new MediaRecorder(stream, {
        mimeType: selectedMime,
        videoBitsPerSecond: 8000000 // 8 Mbps
      });
    } catch (e) {
      recorder = new MediaRecorder(stream);
    }

    recorder.ondataavailable = (e) => {
      if (e.data && e.data.size > 0) {
        chunks.push(e.data);
      }
    };

    const recordPromise = new Promise((resolve) => {
      recorder.onstop = () => {
        const videoBlob = new Blob(chunks, { type: selectedMime });
        resolve(videoBlob);
      };
    });

    recorder.start();

    // 2. Render each photo frame to canvas
    const total = sortedPhotos.length;
    const frameDurationMs = 1000 / fps;

    for (let i = 0; i < total; i++) {
      const progress = 0.10 + (i / total) * 0.85;
      reportProgress(progress, `Processing frame ${i + 1} of ${total}…`);

      const photo = sortedPhotos[i];
      const img = await EyeDetection.loadImage(photo.blob);

      ctx.save();
      ctx.fillStyle = '#000000';
      ctx.fillRect(0, 0, videoWidth, videoHeight);

      if (alignEyes && refEyes) {
        // Detect eyes for current frame
        let currentEyes = null;
        try {
          currentEyes = await EyeDetection.detectEyes(img);
        } catch (e) {
          currentEyes = null;
        }

        if (currentEyes) {
          this.drawAlignedFrame(ctx, img, currentEyes, refEyes, videoWidth, videoHeight);
        } else {
          this.drawAspectFitFrame(ctx, img, videoWidth, videoHeight);
        }
      } else {
        this.drawAspectFitFrame(ctx, img, videoWidth, videoHeight);
      }

      ctx.restore();

      // Wait frame duration for MediaRecorder to encode frame
      await new Promise(r => setTimeout(r, frameDurationMs));
    }

    reportProgress(0.96, 'Finalizing video encoding…');
    recorder.stop();

    const resultVideoBlob = await recordPromise;
    this.isExporting = false;
    reportProgress(1.0, 'Export complete!');

    return {
      blob: resultVideoBlob,
      mimeType: selectedMime,
      url: URL.createObjectURL(resultVideoBlob),
      filename: `PocketPic_TimeLapse_${Date.now()}.${selectedMime.includes('mp4') ? 'mp4' : 'webm'}`
    };
  },

  drawAspectFitFrame(ctx, img, targetW, targetH) {
    const imgW = img.naturalWidth || img.width;
    const imgH = img.naturalHeight || img.height;

    const scale = Math.min(targetW / imgW, targetH / imgH);
    const drawW = imgW * scale;
    const drawH = imgH * scale;
    const x = (targetW - drawW) / 2;
    const y = (targetH - drawH) / 2;

    ctx.drawImage(img, x, y, drawW, drawH);
  },

  drawAlignedFrame(ctx, img, currentEyes, refEyes, targetW, targetH) {
    const srcLeft = currentEyes.leftEye;
    const srcRight = currentEyes.rightEye;
    const dstLeft = refEyes.leftEye;
    const dstRight = refEyes.rightEye;

    // Calculate similarity transform (scale, rotation, translation)
    const srcDx = srcRight.x - srcLeft.x;
    const srcDy = srcRight.y - srcLeft.y;
    const srcDist = Math.hypot(srcDx, srcDy);

    const dstDx = dstRight.x - dstLeft.x;
    const dstDy = dstRight.y - dstLeft.y;
    const dstDist = Math.hypot(dstDx, dstDy);

    if (srcDist < 10 || dstDist < 10) {
      this.drawAspectFitFrame(ctx, img, targetW, targetH);
      return;
    }

    const scale = dstDist / srcDist;
    const angle = Math.atan2(dstDy, dstDx) - Math.atan2(srcDy, srcDx);

    ctx.translate(dstLeft.x, dstLeft.y);
    ctx.rotate(angle);
    ctx.scale(scale, scale);
    ctx.translate(-srcLeft.x, -srcLeft.y);

    ctx.drawImage(img, 0, 0);
  }
};

window.Exporter = Exporter;
