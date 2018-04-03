export default `<!DOCTYPE html>
<html>

  <head>

    <meta charset="utf-8"/>

    <title>hls.js demo</title>

    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.4/css/bootstrap.min.css">
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.4/css/bootstrap-theme.min.css">

    <link rel="stylesheet" href="https://video-dev.github.io/hls.js/demo/style.css">

    <script src="https://ajax.googleapis.com/ajax/libs/jquery/2.1.3/jquery.min.js"></script>
    <script src="https://maxcdn.bootstrapcdn.com/bootstrap/3.3.4/js/bootstrap.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/FileSaver.js/1.3.3/FileSaver.min.js"></script>

  </head>

  <body>
    <div class="header-container">
      <header class="wrapper clearfix">
        <h1>
          <a target="_blank" href="https://github.com/video-dev/hls.js">
            <img src="https://cloud.githubusercontent.com/assets/616833/19739063/e10be95a-9bb9-11e6-8100-2896f8500138.png"/>
          </a>
        </h1>

        <h2 class="title">
          demo
        </h2>

        <h3>
          <a href="../docs/html">API docs | usage guide</a>
        </h3>
      </header>
    </div>

    <div class="main-container">
      <header>
        <p>
          Test your HLS streams in all supported browsers (Chrome/Firefox/IE11/Edge/Safari).
        </p>
        <p>
          Advanced controls are available at the bottom of this page.
        </p>
        <p>
          <b>Looking for a more <i>basic</i> usage example? Go <a href="basic-usage.html">here</a>.</b><br>
        </p>
      </header>
      <div id="controls">

        <div id="customButtons"></div>

        <select id="streamSelect" class="innerControls">
          <option value="" selected>Select a test-stream from drop-down menu. Or enter custom URL below</option>
        </select>

        <input id="streamURL" class="innerControls" type=text value=""/>

        <label class="innerControls">
          Enable streaming:
          <input id="enableStreaming" type=checkbox checked/>
        </label>

        <label class="innerControls">
          Auto-recover media-errors:
          <input id="autoRecoverError" type=checkbox checked/>
        </label>

        <label class="innerControls">
          Enable worker for transmuxing:
          <input id="enableWorker" type=checkbox checked/>
        </label>

        <label class="innerControls">
          Dump transmuxed fMP4 data:
          <input id="dumpfMP4" type=checkbox unchecked/>
        </label>

        <label class="innerControls">
          Widevine DRM license-server URL:
          <input id="widevineLicenseUrl" style="width: 50%"/>
        </label>

        <label class="innerControls">
          Level-cap'ing (max limit):
          <input id="levelCapping" style="width: 8em" type=number/>
        </label>

        <label class="innerControls">
          Default audio-codec:
          <input style="width: 8em" id="defaultAudioCodec"/>
        </label>

        <label class="innerControls">
          Player size:
          <select id="videoSize" style="float:right;">
            <option value="240">Tiny (240p)</option>
            <option value="384">Small (384p)</option>
            <option value="480">Medium (480p)</option>
            <option value="720" selected>Large (720p)</option>
            <option value="1080">Huge (1080p)</option>
          </select>
        </label>

        <label class="innerControls">
          Current video-resolution:
          <span id="currentResolution">/</span>
        </label>

        <label class="innerControls">
          Permalink:&nbsp;
          <span id="StreamPermalink" style="width: 50%"></span>
        </label>

      </div>

      <video id="video" controls autoplay class="videoCentered"></video>

      <br>

      <canvas id="buffered_c" height="15" class="videoCentered" onclick="onClickBufferedRange(event);"></canvas>

      <br><br>

      <pre id="HlsStatus" class="center" style="white-space: pre-wrap;"></pre>

      <div class="center" style="text-align: center;" id="toggleButtons">
        <button type="button" class="btn btn-sm" onclick="$('#PlaybackControl').toggle();">Playback controls</button>
        <button type="button" class="btn btn-sm" onclick="$('#QualityLevelControl').toggle();">Quality-level controls</button>
        <button type="button" class="btn btn-sm" onclick="$('#AudioTrackControl').toggle();">Audio-track controls</button>
        <button type="button" class="btn btn-sm" onclick="$('#MetricsDisplay').toggle();toggleMetricsDisplay();">Metrics-display</button>
        <button type="button" class="btn btn-sm" onclick="$('#StatsDisplay').toggle();">Stats-display</button>
      </div>

      <div class="center" id='PlaybackControl'>
        <h4>Playback controls</h4>

        <center>
            <p>
              <button type="button" class="btn btn-sm btn-info" onclick="$('#video')[0].play()">Play</button>
              <button type="button" class="btn btn-sm btn-info" onclick="$('#video')[0].pause()">Pause</button>
            </p>

            <p>
              <button type="button" class="btn btn-sm btn-info" onclick="$('#video')[0].currentTime-=10">- 10 s</button>
              <button type="button" class="btn btn-sm btn-info" onclick="$('#video')[0].currentTime+=10">+ 10 s</button>
            </p>

            <p>
              <button type="button" class="btn btn-sm btn-info" onclick="$('#video')[0].currentTime=$('#seek_pos').val()">seek to </button>
              <input type="text" id='seek_pos' size="8" onkeydown="if(window.event.keyCode=='13'){$('#video')[0].currentTime=$('#seek_pos').val();}">
            </p>

            <p>
              <button type="button" class="btn btn-xs btn-warning" onclick="hls.attachMedia($('#video')[0])">Attach media</button>
              <button type="button" class="btn btn-xs btn-warning" onclick="hls.detachMedia()">Detach media</button>
            </p>

            <p>
              <button type="button" class="btn btn-xs btn-warning" onclick="hls.startLoad()">Start loading</button>
              <button type="button" class="btn btn-xs btn-warning" onclick="hls.stopLoad()">Stop loading</button>
            </p>

            <p>
              <button type="button" class="btn btn-xs btn-warning" onclick="hls.recoverMediaError()">Recover media-error</button>
            </p>

            <p>
              <button type="button" class="btn btn-xs btn-warning" onclick="createfMP4('audio');">Create audio-fmp4</button>
              <button type="button" class="btn btn-xs btn-warning" onclick="createfMP4('video')">Create video-fmp4</button>
            </p>
        </center>

      </div>

      <div class="center" id='QualityLevelControl'>
        <h4>Quality-level controls</h4>
        <center>
            <table>
                <tr>
                  <td>
                    <p>Currently played level</p>
                  </td>
                  <td>
                    <div id="currentLevelControl" style="display: inline;"></div>
                  </td>
                </tr>
                <tr>
                  <td>
                    <p>Next level loaded</p>
                  </td>
                  <td>
                    <div id="nextLevelControl" style="display: inline;"></div>
                  </td>
                </tr>
                <tr>
                  <td>
                    <p>Currently loaded level</p>
                  </td>
                  <td>
                    <div id="loadLevelControl" style="display: inline;"></div>
                  </td>
                </tr>
                <tr>
                  <td>
                    <p>Cap-limit level (maximum)</p>
                  </td>
                  <td>
                    <div id="levelCappingControl" style="display: inline;"></div>
                  </td>
                </tr>
              </table>
        </center>
      </div>

      <div class="center" id='AudioTrackControl'>
        <h4>Audio-track controls</h4>
        <table>
          <tr>
            <td>Current audio-track</td>
            <td width=10px></td>
            <td> <div id="audioTrackControl" style="display: inline;"></div> </td>
          </tr>
        </table>
      </div>

      <div class="center" id='MetricsDisplay'>
        <h4>Real-time metrics</h4>
        <div id="metricsButton">
          <button type="button" class="btn btn-xs btn-info" onclick="$('#metricsButtonWindow').toggle();$('#metricsButtonFixed').toggle();windowSliding=!windowSliding; refreshCanvas()">toggle sliding/fixed window</button><br>
          <div id="metricsButtonWindow">
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSetSliding(0)">window ALL</button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSetSliding(2000)">2s</button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSetSliding(5000)">5s</button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSetSliding(10000)">10s</button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSetSliding(20000)">20s</button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSetSliding(30000)">30s</button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSetSliding(60000)">60s</button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSetSliding(120000)">120s</button><br>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeZoomIn()">Window Zoom In</button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeZoomOut()">Window Zoom Out</button><br>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSlideLeft()"> <<< Window Slide </button>
            <button type="button" class="btn btn-xs btn-info" onclick="timeRangeSlideRight()">Window Slide >>> </button><br>
          </div>
          <div id="metricsButtonFixed">
            <button type="button" class="btn btn-xs btn-info" onclick="windowStart=$('#windowStart').val()">fixed window start(ms)</button>
            <input type="text" id='windowStart' defaultValue="0" size="8" onkeydown="if(window.event.keyCode=='13'){windowStart=$('#windowStart').val();}">
            <button type="button" class="btn btn-xs btn-info" onclick="windowEnd=$('#windowEnd').val()">fixed window end(ms)</button>
            <input type="text" id='windowEnd' defaultValue="10000" size="8" onkeydown="if(window.event.keyCode=='13'){windowEnd=$('#windowEnd').val();}"><br>
          </div>
          <button type="button" class="btn btn-xs btn-success" onclick="goToMetrics()" style="font-size:18px">metrics link</button>
          <button type="button" class="btn btn-xs btn-success" onclick="goToMetricsPermaLink()" style="font-size:18px">metrics permalink</button>
          <button type="button" class="btn btn-xs btn-success" onclick="copyMetricsToClipBoard()" style="font-size:18px">copy metrics to clipboard</button>
          <canvas id="bufferTimerange_c" width="640" height="100" style="border:1px solid #000000" onmousedown="timeRangeCanvasonMouseDown(event)" onmousemove="timeRangeCanvasonMouseMove(event)" onmouseup="timeRangeCanvasonMouseUp(event)" onmouseout="timeRangeCanvasonMouseOut(event);"></canvas>
          <canvas id="bitrateTimerange_c" width="640" height="100" style="border:1px solid #000000;"></canvas>
          <canvas id="bufferWindow_c" width="640" height="100" style="border:1px solid #000000" onmousemove="windowCanvasonMouseMove(event);"></canvas>
          <canvas id="videoEvent_c" width="640" height="15" style="border:1px solid #000000;"></canvas>
          <canvas id="loadEvent_c" width="640" height="15" style="border:1px solid #000000;"></canvas><br>
        </div>
      </div>

      <div class="center" id='StatsDisplay'>
        <h4>Stats</h4>
        <pre id='HlsStats'></pre>
        <div id="buffered_log"></div>
      </div>

    </div>

    <footer>
      <br><br><br><br><br><br>
    </footer>

    <!-- Demo page required libs -->
    <script src="https://video-dev.github.io/hls.js/demo/canvas.js"></script>
    <script src="https://video-dev.github.io/hls.js/demo/metrics.js"></script>
    <script src="https://video-dev.github.io/hls.js/demo/jsonpack.js"></script>

    <!-- Compiled lib dist -->
    <script src="https://video-dev.github.io/hls.js/dist/hls.js"></script>
    <!-- Compiled demo main -->
    <script src="/hls-demo.js"></script>
  </body>
</html>
`;
