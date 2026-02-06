import { webview } from '@kit.ArkWeb';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

// 定义 Proxy 接口，用于 TS 类型检查
interface JsProxyObject {
  postMessage: (jsonStr: string) => void;
}

// 独立的滑动条组件
@Component
struct ControlSlider {
  @Prop label: string;
  @Prop color: string;
  @Prop min: number;
  @Prop max: number;
  @Link value: number;
  @Prop step: number;

  onValueChange: (val: number) => void = (val: number): void => {};

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.label).fontSize(12).fontColor(Color.White).fontWeight(FontWeight.Medium).shadow({ radius: 2, color: 'rgba(0,0,0,0.5)' })
        Blank()
        Text(this.value.toFixed(this.step < 1 ? 2 : 0)).fontSize(12).fontColor(this.color).fontWeight(FontWeight.Bold).shadow({ radius: 2, color: 'rgba(0,0,0,0.5)' })
      }
      .width('100%')

      Slider({ value: this.value, min: this.min, max: this.max, step: this.step, style: SliderStyle.OutSet })
        .blockColor(this.color)
        .trackColor('rgba(255,255,255,0.2)')
        .selectedColor(this.color)
        .showSteps(false)
        .onChange((v: number): void => {
          this.value = v;
          this.onValueChange(v);
        })
    }
    .width('100%')
  }
}

// 独立的开关组件
@Component
struct ControlSwitch {
  @Prop label: string;
  @Prop color: string;
  @Link isOn: boolean;

  onChange: (isOn: boolean) => void = (isOn: boolean): void => {};

  build() {
    Row() {
      Text(this.label).fontSize(12).fontColor(Color.White).fontWeight(FontWeight.Medium).shadow({ radius: 2, color: 'rgba(0,0,0,0.5)' })
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(this.color)
        .switchPointColor('#FFFFFF')
        .onChange((isOn: boolean) => {
          this.isOn = isOn;
          this.onChange(isOn);
        })
        .height(24)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }
}

@Entry
@Component
struct Index {
  // --- 滤镜参数 (按照新分类整理) ---

  // 1. 基础 (Basic)
  @State threshold: number = 240; // 亮度阈值 (0-255)
  @State dilationEnabled: boolean = true; // 启用膨胀
  @State dilationIter: number = 1; // 膨胀次数
  @State dilationSize: number = 1; // 膨胀核大小

  // 2. 过滤 (Filter)
  @State minAreaEnabled: boolean = true;
  @State minArea: number = 25;
  @State maxAreaEnabled: boolean = true;
  @State maxAreaRatio: number = 1000; // 1/N
  @State shapeFilterEnabled: boolean = true;
  @State circularity: number = 0.3;

  // 3. 星芒 (Starburst)
  @State starLengthMin: number = 40;
  @State starLengthMax: number = 120;
  @State starOpacity: number = 0.8;
  @State starPoints: number = 4; // 星芒线数 (4, 6, 8)
  @State starAngle: number = 0; // 旋转角度
  @State starColorTemp: number = 0; // 色温/颜色倾向 (预留)

  // 4. 色彩 (Color)
  @State starSaturation: number = 1.0; // 色彩饱和度增强 (1.0 = 原色)

  // 5. 相机 (Camera)
  @State cameraZoom: number = 1.0;
  @State cameraExposure: number = 0.0;

  // 旧参数兼容
  @State maxSourceSize: number = 1000; // 兼容旧逻辑，对应 maxArea
  @State maxRatio: number = 3.5; // 兼容旧逻辑

  // 状态参数
  @State isCameraRunning: boolean = false;
  @State fps: string = "0";
  @State isEngineReady: boolean = false;
  @State isMenuOpen: boolean = false;

  // UI模式标记
  @State isStaticMode: boolean = false;
  @State isPermissionGranted: boolean = false;

  // 当前选中的参数类别
  @State currentCategory: string = '基础';

  private categories: string[] = ['智能', '基础', '星芒', '色彩', '过滤', '相机', '高级'];

  private controller: webview.WebviewController = new webview.WebviewController();
  private isSaving: boolean = false;

  // --- 1. 保存图片到相册核心逻辑 ---
  private async saveImageToGallery(base64Data: string): Promise<void> {
    try {
      if (!base64Data || base64Data.length < 100) return;

      const base64Str = base64Data.split(',')[1];
      const base64Helper = new util.Base64Helper();
      const buffer = base64Helper.decodeSync(base64Str);

      const context = getContext(this) as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(context);

      const creationConfig: photoAccessHelper.PhotoCreationConfig = {
        title: `StarFilter_${new Date().getTime()}`,
        fileNameExtension: 'png',
        photoType: photoAccessHelper.PhotoType.IMAGE,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT,
      };

      const uri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png', creationConfig);
      const file = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE);
      await fileIo.write(file.fd, buffer.buffer);
      await fileIo.close(file.fd);

      promptAction.showToast({ message: '✨ 照片已保存', duration: 2000 });
    } catch (err) {
      console.error('Save failed:', JSON.stringify(err));
      promptAction.showToast({ message: '保存失败: ' + (err as BusinessError).message });
    } finally {
      this.isSaving = false;
    }
  }

  // --- 2. 从相册选择图片逻辑 ---
  private async selectImageFromGallery(): Promise<void> {
    try {
      const PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      PhotoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      PhotoSelectOptions.maxSelectNumber = 1;

      const photoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoViewPicker.select(PhotoSelectOptions);

      if (result.photoUris.length > 0) {
        const uri = result.photoUris[0];

        // 读取文件
        const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
        const fileSize = fileIo.statSync(file.fd).size;
        const buffer = new ArrayBuffer(fileSize);
        await fileIo.read(file.fd, buffer);
        await fileIo.close(file.fd);

        // 转 Base64 并发给 Web
        const base64Helper = new util.Base64Helper();
        const base64Str = base64Helper.encodeToStringSync(new Uint8Array(buffer));
        const fullBase64 = `data:image/png;base64,${base64Str}`;

        if (this.isEngineReady) {
          this.isStaticMode = true; // 切换UI到图片模式
          this.controller.runJavaScript(`loadStaticImage('${fullBase64}')`);
          this.isMenuOpen = false;  // 选完图自动收起菜单
        }
      }
    } catch (err) {
      console.error('Select image failed:', err);
    }
  }

  // --- 3. JS 交互代理 ---
  private jsProxyObject: JsProxyObject = {
    postMessage: (jsonStr: string): void => {
      try {
        const data = JSON.parse(jsonStr) as Record<string, string | number>;

        if (data.type === 'status' && data.msg === 'ready') {
          console.info('Web: OpenCV Ready');
          this.isEngineReady = true;
          // 初始化参数到 Web
          this.syncAllParams();

          if (this.isPermissionGranted) {
            setTimeout((): void => { this.toggleCamera(true); }, 200);
          }
        }
        else if (data.type === 'fps') {
          this.fps = data.value.toString();
        }
        else if (data.type === 'error') {
          console.error('Web Error:', data.msg);
        }
        else if (data.type === 'capture') {
          this.saveImageToGallery(data.data as string);
        }
      } catch (e) {
        console.error('Proxy Error', e);
      }
    }
  };

  async aboutToAppear(): Promise<void> {
    await this.requestPermissions();
  }

  private async requestPermissions(): Promise<void> {
    let atManager = abilityAccessCtrl.createAtManager();
    let context = getContext(this) as common.UIAbilityContext;
    const permissions: Array<Permissions> = ['ohos.permission.CAMERA'];

    try {
      let grantStatus = await atManager.checkAccessToken(context.applicationInfo.accessTokenId, permissions[0]);

      if (grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.isPermissionGranted = true;
        if (this.isEngineReady) {
          this.toggleCamera(true);
        }
      } else {
        let requestResult = await atManager.requestPermissionsFromUser(context, permissions);
        if (requestResult.authResults.every(result => result === 0)) {
          this.isPermissionGranted = true;
          if (this.isEngineReady) {
            setTimeout((): void => { this.toggleCamera(true); }, 200);
          }
        }
      }
    } catch (err) {
      console.error('权限申请失败', err);
    }
  }

  private updateWebParam(key: string, value: number | boolean): void {
    if (this.isEngineReady) {
      // 转换 boolean 为 int (0/1) 传递，或者直接传 bool，JS端处理
      const valToSend = typeof value === 'boolean' ? (value ? 1 : 0) : value;
      this.controller.runJavaScript(`updateParam('${key}', ${valToSend})`);
    }
  }

  private syncAllParams(): void {
    this.updateWebParam('threshold', this.threshold);
    this.updateWebParam('dilationEnabled', this.dilationEnabled);
    this.updateWebParam('dilationIter', this.dilationIter);
    this.updateWebParam('dilationSize', this.dilationSize);

    this.updateWebParam('minAreaEnabled', this.minAreaEnabled);
    this.updateWebParam('minArea', this.minArea);
    this.updateWebParam('maxAreaEnabled', this.maxAreaEnabled);
    this.updateWebParam('maxAreaRatio', this.maxAreaRatio);
    this.updateWebParam('shapeFilterEnabled', this.shapeFilterEnabled);
    this.updateWebParam('circularity', this.circularity);

    this.updateWebParam('starLengthMin', this.starLengthMin);
    this.updateWebParam('starLengthMax', this.starLengthMax);
    this.updateWebParam('starOpacity', this.starOpacity);
    this.updateWebParam('starPoints', this.starPoints);
    this.updateWebParam('starAngle', this.starAngle);
    this.updateWebParam('starSaturation', this.starSaturation);
  }

  private toggleCamera(forceStart?: boolean): void {
    if (forceStart !== undefined) this.isCameraRunning = forceStart;
    else this.isCameraRunning = !this.isCameraRunning;

    if (this.isCameraRunning) {
      this.isStaticMode = false;
    }

    if (this.isEngineReady) {
      this.controller.runJavaScript(`toggleCamera(${this.isCameraRunning})`);
    }
  }

  private switchCamera(): void {
    this.isStaticMode = false;
    if (this.isEngineReady) this.controller.runJavaScript(`switchCamera()`);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Web({ src: $rawfile('star_filter.html'), controller: this.controller })
        .javaScriptAccess(true)
        .fileAccess(true)
        .domStorageAccess(true)
        .imageAccess(true)
        .onlineImageAccess(true)
        .mixedMode(MixedMode.All)
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Black)
        .javaScriptProxy({
          object: this.jsProxyObject,
          name: "etsProxy",
          methodList: ["postMessage"],
          controller: this.controller,
        })
        .onPermissionRequest((event) => {
          if (event) {
            event.request.grant(event.request.getAccessibleResource());
          }
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 顶部状态栏
      Row() {
        Text(this.isStaticMode ? '🖼️ 图片修饰模式' : '✨ 物理星光镜 Pro')
          .fontColor(Color.White).fontSize(16).fontWeight(FontWeight.Bold).shadow({ radius: 3, color: 'rgba(0,0,0,0.8)' })
        Blank()
        Row({ space: 4 }) {
          Text('FPS').fontSize(10).fontColor('#4ADE80').fontWeight(FontWeight.Bold)
          Text(this.fps).fontSize(14).fontColor('#4ADE80').fontFamily('Monospace')
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor('rgba(0,0,0,0.4)')
        .borderRadius(12)
        .opacity(this.isStaticMode ? 0 : 1)
      }
      .width('100%').padding({ left: 20, right: 20, top: 40 }).position({ x: 0, y: 0 }).hitTestBehavior(HitTestMode.None)

      Column() {
        // 弹出菜单区域
        if (this.isMenuOpen) {
          Column() {
            // 1. 类别选择栏
            List({ space: 12 }) {
              ForEach(this.categories, (item: string) => {
                ListItem() {
                  Text(item)
                    .fontSize(14)
                    .fontColor(this.currentCategory === item ? '#141414' : Color.White)
                    .fontWeight(this.currentCategory === item ? FontWeight.Bold : FontWeight.Normal)
                    .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                    .backgroundColor(this.currentCategory === item ? Color.White : 'rgba(255,255,255,0.1)')
                    .borderRadius(16)
                    .onClick(() => {
                      this.currentCategory = item;
                    })
                }
              })
            }
            .listDirection(Axis.Horizontal)
            .width('100%')
            .height(40)
            .margin({ bottom: 16 })
            .scrollBar(BarState.Off)

            // 2. 参数内容区
            Column({ space: 12 }) {
              if (this.currentCategory === '基础') {
                 ControlSlider({ label: '亮度阈值 (Threshold)', value: $threshold, min: 50, max: 255, step: 1, color: '#FFD700', onValueChange: (v) => this.updateWebParam('threshold', v) })

                 Divider().color('rgba(255,255,255,0.1)').margin({top: 4, bottom: 4})

                 ControlSwitch({ label: '启用膨胀 (Dilation)', color: '#4ADE80', isOn: $dilationEnabled, onChange: (v) => this.updateWebParam('dilationEnabled', v) })
                 if (this.dilationEnabled) {
                   ControlSlider({ label: '膨胀次数', value: $dilationIter, min: 1, max: 5, step: 1, color: '#4ADE80', onValueChange: (v) => this.updateWebParam('dilationIter', v) })
                   ControlSlider({ label: '核大小', value: $dilationSize, min: 1, max: 9, step: 2, color: '#4ADE80', onValueChange: (v) => this.updateWebParam('dilationSize', v) })
                 }

              } else if (this.currentCategory === '过滤') {
                 ControlSwitch({ label: '启用最小面积过滤', color: '#60A5FA', isOn: $minAreaEnabled, onChange: (v) => this.updateWebParam('minAreaEnabled', v) })
                 if (this.minAreaEnabled) {
                   ControlSlider({ label: '最小面积 (px)', value: $minArea, min: 1, max: 100, step: 1, color: '#60A5FA', onValueChange: (v) => this.updateWebParam('minArea', v) })
                 }

                 ControlSwitch({ label: '启用最大面积过滤', color: '#F472B6', isOn: $maxAreaEnabled, onChange: (v) => this.updateWebParam('maxAreaEnabled', v) })
                 if (this.maxAreaEnabled) {
                   ControlSlider({ label: '最大面积比例 (1/N)', value: $maxAreaRatio, min: 100, max: 5000, step: 100, color: '#F472B6', onValueChange: (v) => this.updateWebParam('maxAreaRatio', v) })
                 }

                 ControlSwitch({ label: '启用形状(圆形度)过滤', color: '#A78BFA', isOn: $shapeFilterEnabled, onChange: (v) => this.updateWebParam('shapeFilterEnabled', v) })
                  if (this.shapeFilterEnabled) {
                    ControlSlider({ label: '圆形度阈值', value: $circularity, min: 0.1, max: 1.0, step: 0.05, color: '#A78BFA', onValueChange: (v) => this.updateWebParam('circularity', v) })
                  }


              } else if (this.currentCategory === '星芒') {
                 ControlSlider({ label: '最小星芒长度', value: $starLengthMin, min: 10, max: 200, step: 5, color: '#FCD34D', onValueChange: (v) => this.updateWebParam('starLengthMin', v) })
                 ControlSlider({ label: '最大星芒长度', value: $starLengthMax, min: 50, max: 500, step: 10, color: '#FCD34D', onValueChange: (v) => this.updateWebParam('starLengthMax', v) })
                 ControlSlider({ label: '星芒透明度', value: $starOpacity, min: 0.1, max: 1.0, step: 0.1, color: '#FFFFFF', onValueChange: (v) => this.updateWebParam('starOpacity', v) })

                 Divider().color('rgba(255,255,255,0.1)').margin({top: 4, bottom: 4})

                 ControlSlider({ label: '星芒线数 (4/6/8)', value: $starPoints, min: 4, max: 8, step: 2, color: '#FCD34D', onValueChange: (v) => this.updateWebParam('starPoints', v) })
                 ControlSlider({ label: '旋转角度', value: $starAngle, min: 0, max: 180, step: 1, color: '#FCD34D', onValueChange: (v) => this.updateWebParam('starAngle', v) })

              } else if (this.currentCategory === '色彩') {
                 ControlSlider({ label: '色彩饱和度', value: $starSaturation, min: 0.0, max: 3.0, step: 0.1, color: '#F472B6', onValueChange: (v) => this.updateWebParam('starSaturation', v) })
              } else if (this.currentCategory === '相机') {
                  if (this.isStaticMode) {
                     Text('相机控制在这一模式不可用').fontColor(Color.White).opacity(0.5).margin({top: 20})
                  } else {
                     ControlSlider({ label: '变焦 (Zoom)', value: $cameraZoom, min: 1.0, max: 5.0, step: 0.1, color: '#3B82F6', onValueChange: (v) => {
                         if (this.isEngineReady) this.controller.runJavaScript(`setZoom(${v})`);
                     }})
                     ControlSlider({ label: '曝光补偿 (EV)', value: $cameraExposure, min: -2.0, max: 2.0, step: 0.5, color: '#3B82F6', onValueChange: (v) => {
                         if (this.isEngineReady) this.controller.runJavaScript(`setExposure(${v})`);
                     }})
                  }
              } else if (this.currentCategory === '智能') {
                 Text('智能模式正在开发中...').fontColor(Color.White).opacity(0.5).margin({top: 20})
              } else {
                 Text('该模块功能暂未开放').fontColor(Color.White).opacity(0.5).margin({top: 20})
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)

            // 相册选择按钮 (放在菜单底部)
            Row() {
              Button({ type: ButtonType.Normal, stateEffect: true }) {
                Row({ space: 8 }) {
                  Text('🖼️').fontSize(18)
                  Text('从相册选择图片').fontSize(14).fontColor(Color.White)
                }
                .padding({ top: 10, bottom: 10 })
              }
              .width('100%')
              .backgroundColor('rgba(255,255,255,0.15)')
              .borderRadius(8)
              .onClick(() => {
                this.selectImageFromGallery();
              })
            }
            .margin({ top: 20 })

          }
          .width('100%')
          .backgroundColor('rgba(20, 20, 20, 0.95)')
          .backdropBlur(20)
          .padding(24)
          .borderRadius({ topLeft: 24, topRight: 24 })
          .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 300 }))
        }

        // 底部控制栏
        Row() {
          Column() {
            Text('⚙️').fontSize(24).margin({ bottom: 4 })
            Text('参数').fontSize(12).fontColor(this.isMenuOpen ? '#60A5FA' : Color.White)
          }
          .onClick((): void => { animateTo({ duration: 300, curve: Curve.EaseOut }, (): void => { this.isMenuOpen = !this.isMenuOpen; }) })
          .width(60)

          Blank()

          // 快门/保存按钮
          Stack({ alignContent: Alignment.Center }) {
            // 外圈装饰
            Column()
              .width(76)
              .height(76)
              .borderRadius(38)
              .border({ width: 6, color: 'rgba(255, 255, 255, 0.4)' })
              .hitTestBehavior(HitTestMode.None)

            // 内圈保存按钮 (使用 SaveButton 以获取无感写入权限)
            SaveButton({ icon: SaveIconStyle.FULL_FILLED, buttonType: ButtonType.Circle })
              .onClick(async (event, result) => {
                if (result == 0) {
                  if (this.isEngineReady && !this.isSaving) {
                    this.isSaving = true;
                    this.controller.runJavaScript('captureImage()');
                  }
                } else {
                  promptAction.showToast({ message: '授权失败: ' + result });
                }
              })
              .width(62)
              .height(62)
              .backgroundColor(Color.White)
              .iconColor('#141414')
          }
          .width(76)
          .height(76)

          Blank()

          Column() {
            Text(this.isStaticMode ? '📷' : '🔄').fontSize(24).margin({ bottom: 4 })
            Text(this.isStaticMode ? '相机' : '翻转').fontSize(12).fontColor(Color.White)
          }
          .onClick((): void => {
            if (this.isStaticMode) {
              this.toggleCamera(true);
            } else {
              this.switchCamera();
            }
          })
          .width(60)
        }
        .width('100%').padding({ left: 30, right: 30, top: 20, bottom: 40 }).backgroundColor(this.isMenuOpen ? '#141414' : 'transparent')
      }
      .width('100%')
    }
  }
}