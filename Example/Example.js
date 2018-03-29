import React from 'react';
import { Image, StatusBar, StyleSheet, TouchableOpacity, View } from 'react-native';
import Camera, { RNCamera } from 'react-native-camera';
import StaticServer from 'react-native-static-server';
import RNFS from 'react-native-fs';
import indexString from './hls-index.html.js';
import demoJsString from './hls-demo-string.js';

const playlistPath = `${RNFS.DocumentDirectoryPath}/playlist.m3u8`;

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  preview: {
    flex: 1,
    justifyContent: 'flex-end',
    alignItems: 'center',
  },
  overlay: {
    position: 'absolute',
    padding: 16,
    right: 0,
    left: 0,
    alignItems: 'center',
  },
  topOverlay: {
    top: 0,
    flex: 1,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  bottomOverlay: {
    bottom: 0,
    backgroundColor: 'rgba(0,0,0,0.4)',
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
  },
  captureButton: {
    padding: 15,
    backgroundColor: 'white',
    borderRadius: 40,
  },
  typeButton: {
    padding: 5,
  },
  flashButton: {
    padding: 5,
  },
  buttonsSpace: {
    width: 10,
  },
});

export default class Example extends React.Component {
  constructor(props) {
    super(props);

    this.camera = null;

    this.state = {
      camera: {
        flashMode: RNCamera.Constants.FlashMode.on,
      },
      isRecording: false,
    };
  }

  async componentWillMount() {
    this.server = new StaticServer(8080, RNFS.DocumentDirectoryPath);
    if (await RNFS.exists(playlistPath)) {
      await RNFS.unlink(playlistPath);
    }
    const indexPath = `${RNFS.DocumentDirectoryPath}/index.html`;
    if (await RNFS.exists(indexPath)) {
      await RNFS.unlink(indexPath);
    }
    await RNFS.writeFile(indexPath, indexString, 'utf8');
    const demoJsPath = `${RNFS.DocumentDirectoryPath}/hls-demo.js`;
    if (await RNFS.exists(demoJsPath)) {
      await RNFS.unlink(demoJsPath);
    }
    await RNFS.writeFile(demoJsPath, demoJsString, 'utf8');
    this.url = await this.server.start();
    console.log(`Web server started, visit ${this.url} to verify.`);
    this.serveNotification = false;
  }

  componentWillUnmount() {
    this.server.stop();
  }

  takePicture = () => {
    if (this.camera) {
      this.camera
        .takePictureAsync()
        .then(data => console.log(data))
        .catch(err => console.error(err));
    }
  };

  startRecording = () => {
    if (this.camera) {
      this.camera
        .recordAsync({})
        .then(data => console.log(data))
        .catch(err => console.error(err));
      this.setState({
        isRecording: true,
      });
    }
  };

  stopRecording = () => {
    if (this.camera) {
      this.camera.stopRecording();
      this.setState({
        isRecording: false,
      });
    }
  };

  switchType = () => {
    let newType;
    const { back, front } = Camera.constants.Type;

    if (this.state.camera.type === back) {
      newType = front;
    } else if (this.state.camera.type === front) {
      newType = back;
    }

    this.setState({
      camera: {
        ...this.state.camera,
        type: newType,
      },
    });
  };

  get typeIcon() {
    let icon;
    const { back, front } = Camera.constants.Type;

    if (this.state.camera.type === back) {
      icon = require('./assets/ic_camera_rear_white.png');
    } else if (this.state.camera.type === front) {
      icon = require('./assets/ic_camera_front_white.png');
    }

    return icon;
  }

  switchFlash = () => {
    let newFlashMode;
    const { auto, on, off } = RNCamera.Constants.FlashMode;

    if (this.state.camera.flashMode === auto) {
      newFlashMode = on;
    } else if (this.state.camera.flashMode === on) {
      newFlashMode = off;
    } else if (this.state.camera.flashMode === off) {
      newFlashMode = auto;
    }

    this.setState({
      camera: {
        ...this.state.camera,
        flashMode: newFlashMode,
      },
    });
  };

  get flashIcon() {
    let icon;
    const { auto, on, off } = RNCamera.Constants.FlashMode;

    if (this.state.camera.flashMode === auto) {
      icon = require('./assets/ic_flash_auto_white.png');
    } else if (this.state.camera.flashMode === on) {
      icon = require('./assets/ic_flash_on_white.png');
    } else if (this.state.camera.flashMode === off) {
      icon = require('./assets/ic_flash_off_white.png');
    }

    return icon;
  }

  handleSegment = async data => {
    if (!this.state.isRecording) {
      return;
    }
    while (this.handlingSegment) {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    this.handlingSegment = true;
    try {
      if (!this.serveNotification) {
        console.log('Serving at URL', `${this.url}/playlist.m3u8`);
        this.serveNotification = true;
      }
      if (await RNFS.exists(playlistPath)) {
        await RNFS.unlink(playlistPath);
      }
      await RNFS.copyFile(data.manifestPath, playlistPath);
      const segmentPath = `${RNFS.DocumentDirectoryPath}/${data.filename}`;
      if (await RNFS.exists(segmentPath)) {
        await RNFS.unlink(segmentPath);
      }
      await RNFS.copyFile(data.path, segmentPath);
      console.log(JSON.stringify(data, null, 2));
    } catch (error) {
      console.error(error);
    }
    this.handlingSegment = false;
  };

  handleStream = async () => {
    console.log('NEW STREAM');
  };

  render() {
    return (
      <View style={styles.container}>
        <StatusBar animated hidden />
        <RNCamera
          ref={cam => {
            this.camera = cam;
          }}
          style={styles.preview}
          flashMode={this.state.camera.flashMode}
          autoFocus={RNCamera.Constants.AutoFocus.on}
          mirrorImage={false}
          permissionDialogTitle="Sample title"
          permissionDialogMessage="Sample dialog message"
          segmentMode={true}
          onSegment={this.handleSegment}
          onStream={this.handleStream}
        />
        <View style={[styles.overlay, styles.topOverlay]}>
          <TouchableOpacity style={styles.typeButton} onPress={this.switchType}>
            <Image source={this.typeIcon} />
          </TouchableOpacity>
          <TouchableOpacity style={styles.flashButton} onPress={this.switchFlash}>
            <Image source={this.flashIcon} />
          </TouchableOpacity>
        </View>
        <View style={[styles.overlay, styles.bottomOverlay]}>
          {(!this.state.isRecording && (
            <TouchableOpacity style={styles.captureButton} onPress={this.takePicture}>
              <Image source={require('./assets/ic_photo_camera_36pt.png')} />
            </TouchableOpacity>
          )) ||
            null}
          <View style={styles.buttonsSpace} />
          {(!this.state.isRecording && (
            <TouchableOpacity style={styles.captureButton} onPress={this.startRecording}>
              <Image source={require('./assets/ic_videocam_36pt.png')} />
            </TouchableOpacity>
          )) || (
            <TouchableOpacity style={styles.captureButton} onPress={this.stopRecording}>
              <Image source={require('./assets/ic_stop_36pt.png')} />
            </TouchableOpacity>
          )}
        </View>
      </View>
    );
  }
}
