import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../website/js/camera.js', import.meta.url), 'utf8');
function fixture() {
  const draws = [];
  const styles = {};
  const context = { translate() {}, scale() {}, clearRect() {}, drawImage(...args) { draws.push(args); } };
  const video = { videoWidth: 720, videoHeight: 960, style: {}, srcObject: null, play: async () => {}, closest: () => ({ style: { setProperty(key, value) { styles[key] = value; } } }) };
  const settings = new Map();
  const scope = {
    console: { warn() {} }, Blob, URL,
    navigator: { mediaDevices: { getUserMedia: async () => stream(), enumerateDevices: async () => [] } },
    document: { getElementById: () => null, createElement: () => ({ getContext: () => context }) },
    Storage: { getSetting: async (key, fallback) => settings.get(key) ?? fallback, setSetting: async (key, value) => settings.set(key, value) },
    window: { matchMedia: () => ({ matches: true }) }
  };
  vm.runInNewContext(source, scope);
  const camera = scope.window.Camera;
  camera.videoElement = video;
  camera.updateGhostOverlay = async () => {};
  camera.stream = stream();
  return { camera, video, draws, styles, scope, settings };
}
function stream() {
  const track = { stopped: false, stop() { this.stopped = true; }, getSettings: () => ({ facingMode: 'user', deviceId: 'front' }) };
  return { track, getTracks: () => [track], getVideoTracks: () => [track] };
}

test('a portrait phone stream saves a centered landscape image matching the preview', () => {
  const { camera, draws, styles } = fixture();
  camera.adjustViewfinderAspect();
  const frame = camera.captureFrame();
  assert.equal(frame.width, 720);
  assert.equal(frame.height, 540);
  assert.equal(styles['--vf-ratio'], String(4 / 3));
  assert.deepEqual(draws[0].slice(1), [0, 210, 720, 540, 0, 0, 720, 540]);
});

test('portrait selection persists and rotating the source keeps the selected format', async () => {
  const { camera, video, settings } = fixture();
  await camera.togglePhotoOrientation();
  assert.equal(settings.get('photoOrientation'), 'portrait');
  video.videoWidth = 1920;
  video.videoHeight = 1080;
  const frame = camera.captureFrame();
  assert.equal(frame.width, 810);
  assert.equal(frame.height, 1080);
});

test('leaving the camera while permission is pending stops the late stream', async () => {
  const { camera, scope, video } = fixture();
  let resolve;
  const late = stream();
  scope.navigator.mediaDevices.getUserMedia = () => new Promise(done => { resolve = done; });
  const pending = camera.startSession();
  camera.stopSession();
  resolve(late);
  assert.equal(await pending, false);
  assert.equal(late.track.stopped, true);
  assert.equal(video.srcObject, null);
});

test('permission denial does not trigger a second camera request', async () => {
  const { camera, scope } = fixture();
  let requests = 0;
  scope.navigator.mediaDevices.getUserMedia = async () => {
    requests++;
    throw Object.assign(new Error('Denied'), { name: 'NotAllowedError' });
  };
  assert.equal(await camera.startSession(), false);
  assert.equal(requests, 1);
});

test('phone switching requests the other facing direction instead of another lens', async () => {
  const { camera, scope } = fixture();
  camera.currentDeviceId = 'front';
  camera.availableDevices = [{ deviceId: 'front' }, { deviceId: 'rear-wide' }, { deviceId: 'rear-tele' }];
  let request;
  scope.navigator.mediaDevices.getUserMedia = async constraints => { request = constraints; return stream(); };
  await camera.switchCamera();
  assert.equal(request.video.facingMode.ideal, 'environment');
  assert.equal(request.video.deviceId, undefined);
});

test('unchanged background sync preserves rendered thumbnails and open controls', async () => {
  const gallerySource = readFileSync(new URL('../website/js/gallery.js', import.meta.url), 'utf8');
  let photos = [{ id: 'one', date: '2026-11-03', blob: { size: 100 }, updatedAt: 'v1' }];
  const scope = { window: { Storage: true }, Storage: { getAllPhotos: async () => photos }, URL };
  vm.runInNewContext(gallerySource, scope);
  const gallery = scope.window.Gallery;
  gallery.containerElement = { firstElementChild: {} };
  let renders = 0;
  let statusUpdates = 0;
  gallery.render = () => { renders++; };
  gallery.updateSyncStatus = () => { statusUpdates++; };
  await gallery.refresh();
  // IndexedDB returns new record/blob objects on every read.
  photos = [{ ...photos[0], blob: { size: 100 } }];
  await gallery.refresh();
  assert.equal(renders, 1);
  assert.equal(statusUpdates, 1);
  photos = [{ ...photos[0], updatedAt: 'v2' }];
  await gallery.refresh();
  assert.equal(renders, 2);
});
