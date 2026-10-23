//
// Exporter module for PocketPic Web
// Encodes photos into a time-lapse video with optional eye alignment and customizable FPS.
//

// Bundled locally so exports work offline; falls back to the CDN if the file is missing.
const MP4_MUXER_URLS = [
  '../vendor/mp4-muxer.mjs',
  'https://cdn.jsdelivr.net/npm/mp4-muxer@5.2.2/+esm'
];

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

    // 1. Detect eyes on the reference photo, mapped into video space (same target as the iOS export).
    let refEyes = null;
    if (alignEyes && window.EyeDetection) {
      reportProgress(0.04, 'Loading face landmarks…');
      try {
        await EyeDetection.preload();
      } catch (e) {
        console.warn('Face landmark model unavailable:', e);
      }

      reportProgress(0.06, 'Detecting reference eyes…');
      try {
        refEyes = await this.eyesInVideoSpace(firstImg, videoWidth, videoHeight);
        if (!refEyes) console.warn('No face found in the first photo; frames will not be aligned.');
      } catch (e) {
        console.warn('Reference eye detection failed:', e);
      }
    }

    const total = sortedPhotos.length;

    // Draws one photo onto the shared canvas (aspect fit, or eyes aligned to the reference frame).
    const drawFrame = async (photo) => {
      const img = await EyeDetection.loadImage(photo.blob);
      if (!img) return false;

      ctx.save();
      ctx.fillStyle = '#000000';
      ctx.fillRect(0, 0, videoWidth, videoHeight);

      if (alignEyes && refEyes) {
        let aligned = false;
        try {
          const frameEyes = await this.eyesInVideoSpace(img, videoWidth, videoHeight);
          if (frameEyes) aligned = this.drawAlignedFrame(ctx, img, frameEyes, refEyes, videoWidth, videoHeight);
        } catch (e) {
          aligned = false;
        }

        if (!aligned) this.drawAspectFitFrame(ctx, img, videoWidth, videoHeight);
      } else {
        this.drawAspectFitFrame(ctx, img, videoWidth, videoHeight);
      }

      ctx.restore();
      return true;
    };

    // 2. Prefer exact-timestamp encoding (WebCodecs + MP4) so every frame has a fixed duration.
    let mp4Muxer = null;
    let h264Codec = null;
    try {
      h264Codec = await this.pickH264Codec(videoWidth, videoHeight, fps);
      if (h264Codec) {
        mp4Muxer = await this.loadMp4Muxer();
      }
    } catch (e) {
      console.warn('WebCodecs encoding unavailable, falling back to MediaRecorder:', e);
      mp4Muxer = null;
    }

    if (h264Codec && mp4Muxer) {
      try {
        const videoBlob = await this.encodeWithWebCodecs({
          mp4Muxer,
          codec: h264Codec,
          photos: sortedPhotos,
          fps,
          videoWidth,
          videoHeight,
          canvas,
          drawFrame,
          total,
          reportProgress
        });

        this.isExporting = false;
        reportProgress(1.0, 'Export complete!');

        return {
          blob: videoBlob,
          mimeType: 'video/mp4',
          url: URL.createObjectURL(videoBlob),
          filename: `PocketPic_TimeLapse_${Date.now()}.mp4`
        };
      } catch (e) {
        console.warn('WebCodecs export failed, falling back to MediaRecorder:', e);
      }
    }

    // 3. Fallback: capture the canvas in real time with MediaRecorder (variable frame timing).
    return this.encodeWithMediaRecorder({ canvas, photos: sortedPhotos, fps, drawFrame, total, reportProgress });
  },

  async loadMp4Muxer() {
    let lastError = null;
    for (const url of MP4_MUXER_URLS) {
      try {
        const mod = await import(url);
        if (mod && mod.Muxer) return mod;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError || new Error('MP4 muxer unavailable');
  },

  // First H.264 codec string this browser can actually encode at this resolution.
  async pickH264Codec(width, height, fps) {
    if (typeof VideoEncoder === 'undefined' || typeof VideoFrame === 'undefined') return null;

    const candidates = ['avc1.4d0028', 'avc1.640028', 'avc1.4d401f', 'avc1.42E01E', 'avc1.42001f'];
    for (const codec of candidates) {
      try {
        const { supported } = await VideoEncoder.isConfigSupported({
          codec,
          width,
          height,
          bitrate: 8000000,
          framerate: fps
        });
        if (supported) return codec;
      } catch (e) {
        // Unsupported codec strings throw in some browsers; keep trying.
      }
    }
    return null;
  },

  // Encodes each canvas frame with an exact presentation timestamp (frame i at i / fps).
  async encodeWithWebCodecs({ mp4Muxer, codec, photos, fps, videoWidth, videoHeight, canvas, drawFrame, total, reportProgress }) {
    const { Muxer, ArrayBufferTarget } = mp4Muxer;

    const muxer = new Muxer({
      target: new ArrayBufferTarget(),
      video: { codec: 'avc', width: videoWidth, height: videoHeight },
      fastStart: 'in-memory'
    });

    let encoderError = null;
    const encoder = new VideoEncoder({
      output: (chunk, meta) => muxer.addVideoChunk(chunk, meta),
      error: (e) => {
        encoderError = e;
      }
    });

    encoder.configure({
      codec,
      width: videoWidth,
      height: videoHeight,
      bitrate: 8000000,
      framerate: fps,
      latencyMode: 'quality'
    });

    const frameDurationUs = Math.round(1000000 / fps);
    // Derive each timestamp from the frame index so rounding cannot drift over long exports.
    const timestampForFrame = (index) => Math.round((index * 1000000) / fps);
    const keyFrameInterval = Math.max(1, Math.round(fps * 2));

    try {
      for (let i = 0; i < total; i++) {
        if (encoderError) throw encoderError;

        const progress = 0.10 + (i / total) * 0.85;
        reportProgress(progress, `Processing frame ${i + 1} of ${total}…`);

        await drawFrame(photos[i]);

        const frame = new VideoFrame(canvas, {
          timestamp: timestampForFrame(i),
          duration: frameDurationUs
        });
        encoder.encode(frame, { keyFrame: i % keyFrameInterval === 0 });
        frame.close();

        // Let the encoder drain instead of queueing the whole video in memory.
        while (encoder.encodeQueueSize > 4) {
          await new Promise((r) => setTimeout(r, 5));
        }
      }

      reportProgress(0.96, 'Finalizing video encoding…');
      await encoder.flush();
      if (encoderError) throw encoderError;

      muxer.finalize();
      return new Blob([muxer.target.buffer], { type: 'video/mp4' });
    } finally {
      try {
        encoder.close();
      } catch (e) {
        // Already closed by an error.
      }
    }
  },

  // Real-time canvas capture; used only when this browser cannot encode H.264 with WebCodecs.
  async encodeWithMediaRecorder({ canvas, photos, fps, drawFrame, total, reportProgress }) {
    const stream = canvas.captureStream(fps);
    const chunks = [];

    const mimeTypes = [
      'video/mp4;codecs=h264',
      'video/mp4',
      'video/webm;codecs=vp9',
      'video/webm;codecs=vp8',
      'video/webm'
    ];
    let selectedMime = mimeTypes.find(type => MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(type)) || 'video/webm';

    let recorder;
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
        resolve(new Blob(chunks, { type: selectedMime }));
      };
    });

    recorder.start();

    const frameDurationMs = 1000 / fps;

    for (let i = 0; i < total; i++) {
      const progress = 0.10 + (i / total) * 0.85;
      reportProgress(progress, `Processing frame ${i + 1} of ${total}…`);

      await drawFrame(photos[i]);

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

  aspectFitRect(imageWidth, imageHeight, targetW, targetH) {
    const scale = Math.min(targetW / imageWidth, targetH / imageHeight);
    const width = imageWidth * scale;
    const height = imageHeight * scale;
    return { x: (targetW - width) / 2, y: (targetH - height) / 2, width, height };
  },

  drawAspectFitFrame(ctx, img, targetW, targetH) {
    const imgW = img.naturalWidth || img.width;
    const imgH = img.naturalHeight || img.height;
    const fit = this.aspectFitRect(imgW, imgH, targetW, targetH);
    ctx.drawImage(img, fit.x, fit.y, fit.width, fit.height);
  },

  // Eye positions for a frame, expressed in video-canvas pixels.
  async eyesInVideoSpace(img, targetW, targetH) {
    const eyes = await EyeDetection.detectEyes(img);
    if (!eyes) return null;

    const { width, height } = eyes.imageSize;
    const fit = this.aspectFitRect(width, height, targetW, targetH);
    const toVideo = (point) => ({
      x: fit.x + (point.x / width) * fit.width,
      y: fit.y + (point.y / height) * fit.height
    });

    return { left: toVideo(eyes.leftEye), right: toVideo(eyes.rightEye) };
  },

  // Draws the frame so its eyes land on the reference eyes, matching the iOS similarity transform.
  drawAlignedFrame(ctx, img, currentEyes, refEyes, targetW, targetH) {
    const imgW = img.naturalWidth || img.width;
    const imgH = img.naturalHeight || img.height;
    const fit = this.aspectFitRect(imgW, imgH, targetW, targetH);

    let srcLeft = currentEyes.left;
    let srcRight = currentEyes.right;
    const dstDx = refEyes.right.x - refEyes.left.x;
    const dstDy = refEyes.right.y - refEyes.left.y;

    // A mirrored frame would otherwise be rotated 180°; swap the eye pair instead.
    if ((srcRight.x - srcLeft.x) * dstDx + (srcRight.y - srcLeft.y) * dstDy < 0) {
      [srcLeft, srcRight] = [srcRight, srcLeft];
    }

    const srcDist = Math.hypot(srcRight.x - srcLeft.x, srcRight.y - srcLeft.y);
    const dstDist = Math.hypot(dstDx, dstDy);
    if (srcDist < 0.1 || dstDist < 0.1) return false;

    let theta = Math.atan2(dstDy, dstDx) - Math.atan2(srcRight.y - srcLeft.y, srcRight.x - srcLeft.x);
    while (theta > Math.PI) theta -= 2 * Math.PI;
    while (theta < -Math.PI) theta += 2 * Math.PI;
    const scale = dstDist / srcDist;

    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, targetW, targetH);
    ctx.clip();
    ctx.translate(refEyes.left.x, refEyes.left.y);
    ctx.rotate(theta);
    ctx.scale(scale, scale);
    ctx.translate(-srcLeft.x, -srcLeft.y);
    ctx.drawImage(img, fit.x, fit.y, fit.width, fit.height);
    ctx.restore();

    return true;
  }
};

window.Exporter = Exporter;
