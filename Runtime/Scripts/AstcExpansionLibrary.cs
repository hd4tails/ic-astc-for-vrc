using UdonSharp;
using UnityEngine;
using VRC.SDK3.Rendering;
using VRC.SDKBase;
using VRC.Udon;

namespace HDAssets.ImageCompress.Astc
{
    // VRChat/UdonSharp上でnative ASTC byte列から圧縮形式のUnity Textureを生成するライブラリ
    // 処理の流れ:
    // 1. 展開要求を受けてbyte数、画像寸法、実行状態を検証する
    // 2. LoadRawTextureData()でASTC byte列を圧縮状態のままTexture2Dへ読み込む
    // 3. 外部要求でも圧縮Textureをそのまま保持し、要求元へ完了を通知する
    // 4. 結果と状態を更新して呼び出し元へ完了または失敗イベントを送る
    // sourceWidthとsourceHeightには圧縮時の元画像寸法を指定する
    [UdonBehaviourSyncMode(BehaviourSyncMode.NoVariableSync)]
    public class AstcExpansionLibrary : UdonSharpBehaviour
    {
        // ASTCブロックの横幅をpixel単位で示す定数
        public const int BlockWidth = 4;
        // ASTCブロックの縦幅をpixel単位で示す定数
        public const int BlockHeight = 4;
        // ASTCブロック1個あたりのbyte数
        public const int BytesPerBlock = 16;
        // 無効な処理handleを示す値
        public const int InvalidHandleId = -1;
        // 対象handleの状態を判定できないことを示す値
        public const int TaskStateUnknown = 0;
        // 処理開始待ち状態を示す値
        public const int TaskStatePending = 1;
        // 処理実行中状態を示す値
        public const int TaskStateRunning = 2;
        // 処理成功状態を示す値
        public const int TaskStateSucceeded = 3;
        // 処理失敗状態を示す値
        public const int TaskStateFailed = 4;
        // 処理キャンセル状態を示す値
        public const int TaskStateCancelled = 5;
        // 進行段階を判定できないことを示す値
        public const int ProgressStageUnknown = 0;
        // 処理開始待ち段階を示す値
        public const int ProgressStagePending = 1;
        // 入力と出力Textureの準備段階を示す値
        public const int ProgressStagePreparing = 2;
        // ASTC Texture生成と展開処理段階を示す値
        public const int ProgressStageProcessing = 3;
        // GPU完了確認段階を示す値
        public const int ProgressStageReadback = 4;
        // 結果確定と後処理段階を示す値
        public const int ProgressStageFinalizing = 5;
        // 全処理完了段階を示す値
        public const int ProgressStageComplete = 6;
        // 展開成功時に要求元へ送るイベント名
        public const string ExpansionSucceededEventName = "_HandleAstcExpandComplete";
        // 展開失敗時に要求元へ送るイベント名
        public const string ExpansionFailedEventName = "_HandleAstcExpandFailed";
        // 展開warmup成功時に要求元へ送るイベント名
        public const string ExpansionWarmupSucceededEventName = "_HandleAstcExpandWarmupComplete";
        // 展開warmup失敗時に要求元へ送るイベント名
        public const string ExpansionWarmupFailedEventName = "_HandleAstcExpandWarmupFailed";

        // 外部入力による過大なTexture確保を防ぐ。4K画像は許可し、8192超の辺と4K相当を超える総pixel数は拒否する
        private const int MaxExpansionTextureDimension = 8192;
        // 外部入力で許可する画像全体の最大pixel数
        private const long MaxExpansionPixelCount = 16777216L;
        // GPU完了確認用marker Textureの一辺のpixel数
        private const int GpuFenceMarkerSize = 4;

        // 展開元のnative ASTC 4x4 byte列
        [HideInInspector, System.NonSerialized] public byte[] sourceBytes;
        // 展開元画像の横幅
        [HideInInspector, System.NonSerialized] public int sourceWidth;
        // 展開元画像の縦幅
        [HideInInspector, System.NonSerialized] public int sourceHeight;
        // 入力として検証済みのASTC byte数
        [HideInInspector, System.NonSerialized] public int sourceByteCount;
        // 横方向のASTCブロック数
        [HideInInspector, System.NonSerialized] public int blockCountX;
        // 縦方向のASTCブロック数
        [HideInInspector, System.NonSerialized] public int blockCountY;
        // trueならbyte列はsRGB値、falseならlinear値として格納されている

        [HideInInspector, System.NonSerialized] public bool encodedSrgb;

        [Header("Options")]
        // UdonSharpではdelegateを使えないため、完了/失敗はUdonBehaviourのcustom event名で通知する
        [SerializeField] private UdonBehaviour completionEventReceiver;
        [SerializeField] private string completionEventName = "_HandleICExpansionComplete";
        [SerializeField] private string failedEventName = "_HandleICExpansionFailed";

        // ASTC byte列から生成した出力Texture
        [HideInInspector, System.NonSerialized] public Texture outputTexture;
        // 直近の展開処理が成功したかを示すflag
        [HideInInspector, System.NonSerialized] public bool expandComplete;
        // 直近の展開処理が失敗したかを示すflag
        [HideInInspector, System.NonSerialized] public bool expandFailed;
        // 展開warmupが実行中かを示すflag
        [HideInInspector, System.NonSerialized] public bool warmupRunning;
        // 直近の展開warmupが成功したかを示すflag
        [HideInInspector, System.NonSerialized] public bool warmupComplete;
        // 直近の展開warmupが失敗したかを示すflag
        [HideInInspector, System.NonSerialized] public bool warmupFailed;
        // 直近の処理状態を表すmessage
        [HideInInspector, System.NonSerialized] public string status;
        // 展開処理とwarmupのtimeout秒数
        [Min(1f)] public float operationTimeoutSeconds = 60f;

        // 終了通知はGPU使用が終わってから送る。次の要求はその後に受け付ける
        private bool failureNotificationPending;
        private bool cancellationNotificationPending;
        private UdonBehaviour cancellationReceiver;
        private bool disposalRequested;
        private bool disposed;
        public const int TaskStateCancelling = 6;
        public bool IsBusy { get { return expansionPending || warmupRunning || failedGpuResourceReleasePending
            || activeExpansionHandleId != InvalidHandleId || activeExpansionWarmupHandleId != InvalidHandleId; } }
        public bool CanAcceptRequest { get { return !IsBusy && !disposalRequested; } }
        public bool IsDisposed { get { return disposed; } }

        // 前の要求の遅延イベントが残っていても、同じhandleのuploadを重ねない
        private int startedExpansionHandleId = InvalidHandleId;
        private int nextExpansionHandleId;
        private int activeExpansionHandleId = InvalidHandleId;
        private int completedExpansionHandleId = InvalidHandleId;
        private int failedExpansionHandleId = InvalidHandleId;
        private int cancelledExpansionHandleId = InvalidHandleId;
        private bool expansionPending;
        private float expansionStartedAt;
        private UdonBehaviour expansionRequestReceiver;
        private Texture expansionResultTexture;
        private VRCAsyncGPUReadbackRequest gpuFenceReadbackRequest;
        private RenderTexture gpuFenceMarkerTexture;
        private RenderTexture gpuFenceSourceTexture;
        private bool gpuFenceMarkerQueued;
        private bool gpuFenceReadbackQueued;

        // 異常終了時は未完了fenceを待ち、完了後に関連RTを一括解放する
        private bool failedGpuResourceReleasePending;
        private bool gpuFenceReadbackPending;
        private string gpuFenceContinuationEvent = "";
        private int nextExpansionWarmupHandleId;
        private int activeExpansionWarmupHandleId = InvalidHandleId;
        private int completedExpansionWarmupHandleId = InvalidHandleId;
        private int failedExpansionWarmupHandleId = InvalidHandleId;
        private int cancelledExpansionWarmupHandleId = InvalidHandleId;
        private float expansionWarmupStartedAt;
        private UdonBehaviour expansionWarmupRequestReceiver;
        private Texture2D expansionWarmupCompressedTexture;
        private RenderTexture expansionWarmupResultTexture;
        private bool expansionWarmupPending;

        // 実行中の展開handle ID
        public int ActiveExpansionHandleId { get { return activeExpansionHandleId; } }
        // 最後に成功した展開handle ID
        public int CompletedExpansionHandleId { get { return completedExpansionHandleId; } }
        // 最後に失敗した展開handle ID
        public int FailedExpansionHandleId { get { return failedExpansionHandleId; } }
        // 展開要求が実行中かを示すflag
        public bool ExpansionPending { get { return expansionPending; } }
        // 展開成功時の圧縮形式の出力Texture
        public Texture ExpansionResultTexture { get { return expansionResultTexture; } }
        // 実行中の展開warmup handle ID
        public int ActiveExpansionWarmupHandleId { get { return activeExpansionWarmupHandleId; } }
        // 最後に成功した展開warmup handle ID
        public int CompletedExpansionWarmupHandleId { get { return completedExpansionWarmupHandleId; } }
        // 最後に失敗した展開warmup handle ID
        public int FailedExpansionWarmupHandleId { get { return failedExpansionWarmupHandleId; } }

        // 展開要求を登録し、処理を識別するhandle IDを返す
        public int RequestExpansion(
            byte[] inputBytes,
            int width,
            int height,
            bool inputEncodedSrgb,
            UdonBehaviour eventReceiver)
        {
            if (!CanAcceptRequest || inputBytes == null || inputBytes.Length <= 0 || width <= 0 || height <= 0
                || eventReceiver == null || expansionPending || warmupRunning
                || failedGpuResourceReleasePending || activeExpansionHandleId != InvalidHandleId
                || activeExpansionWarmupHandleId != InvalidHandleId)
            {
                SetStatus(eventReceiver == null
                    ? "ASTC expansion event receiver is missing."
                    : "ASTC expansion request is invalid or already pending.");
                return InvalidHandleId;
            }

            _ClearOutputTexture();
            int handleId = GenerateExpansionHandleId();
            activeExpansionHandleId = handleId;
            completedExpansionHandleId = InvalidHandleId;
            failedExpansionHandleId = InvalidHandleId;
            cancelledExpansionHandleId = InvalidHandleId;
            expansionRequestReceiver = eventReceiver;
            expansionResultTexture = null;
            outputTexture = null;
            sourceBytes = inputBytes;
            sourceWidth = width;
            sourceHeight = height;
            encodedSrgb = inputEncodedSrgb;
            expansionPending = true;
            expansionStartedAt = Time.realtimeSinceStartup;
            SendCustomEventDelayedFrames(nameof(_RunRequestedExpansion), 1);
            return handleId;
        }

        // 次frameへ遅延した展開要求を開始する
        public void _RunRequestedExpansion()
        {
            if (!expansionPending || activeExpansionHandleId == InvalidHandleId
                || startedExpansionHandleId == activeExpansionHandleId)
            {
                return;
            }
            startedExpansionHandleId = activeExpansionHandleId;
            _LoadSourceBytesToTexture();
        }

        // 指定handleの展開処理をキャンセルする
        public bool CancelExpansion(int handleId)
        {
            if (handleId == InvalidHandleId || handleId != activeExpansionHandleId || !expansionPending)
            {
                return false;
            }

            failureNotificationPending = false;
            cancellationReceiver = expansionRequestReceiver;
            cancellationNotificationPending = true;
            cancelledExpansionHandleId = handleId;
            expansionPending = false;
            expansionStartedAt = 0f;
            activeExpansionHandleId = InvalidHandleId;
            expansionRequestReceiver = null;
            expansionResultTexture = null;
            sourceBytes = null;
            SetStatus("ASTC expansion cancelled.");
            ReleaseFailedGpuResourcesWhenReadbackCompletes();
            return true;
        }

        // 指定handleの展開状態を返す
        public int GetExpansionState(int handleId)
        {
            if (handleId == InvalidHandleId) return TaskStateUnknown;
            if (handleId == activeExpansionHandleId) return TaskStatePending;
            if (handleId == completedExpansionHandleId) return TaskStateSucceeded;
            if (handleId == failedExpansionHandleId) return failedGpuResourceReleasePending ? TaskStateRunning : TaskStateFailed;
            if (handleId == cancelledExpansionHandleId) return failedGpuResourceReleasePending ? TaskStateCancelling : TaskStateCancelled;
            return TaskStateUnknown;
        }

        // 指定handleの展開進行段階を返す
        public int GetExpansionStage(int handleId)
        {
            if (handleId == completedExpansionHandleId) return ProgressStageComplete;
            if (handleId == activeExpansionHandleId)
            {
                return ProgressStagePending;
            }
            return ProgressStageUnknown;
        }

        // 指定handleの展開進捗を0から1で返す
        public float GetExpansionProgress01(int handleId)
        {
            if (handleId == completedExpansionHandleId) return 1f;
            if (handleId == activeExpansionHandleId)
            {
                return 0f;
            }
            return -1f;
        }

        // 展開warmup要求を登録し、処理を識別するhandle IDを返す
        public int RequestExpansionWarmup(UdonBehaviour eventReceiver)
        {
            if (!CanAcceptRequest || eventReceiver == null || expansionPending || warmupRunning
                || failedGpuResourceReleasePending || activeExpansionHandleId != InvalidHandleId
                || activeExpansionWarmupHandleId != InvalidHandleId)
            {
                SetStatus(eventReceiver == null
                    ? "ASTC expansion warmup event receiver is missing."
                    : "ASTC expansion or warmup is already pending.");
                return InvalidHandleId;
            }

            int handleId = GenerateExpansionWarmupHandleId();
            activeExpansionWarmupHandleId = handleId;
            completedExpansionWarmupHandleId = InvalidHandleId;
            failedExpansionWarmupHandleId = InvalidHandleId;
            cancelledExpansionWarmupHandleId = InvalidHandleId;
            expansionWarmupRequestReceiver = eventReceiver;
            expansionWarmupPending = true;
            warmupRunning = false;
            warmupComplete = false;
            warmupFailed = false;
            expansionWarmupStartedAt = Time.realtimeSinceStartup;
            SendCustomEventDelayedFrames(nameof(_RunRequestedExpansionWarmup), 1);
            return handleId;
        }

        // 登録済みの展開warmup要求を次frameから開始する
        public void _RunRequestedExpansionWarmup()
        {
            if (!expansionWarmupPending || activeExpansionWarmupHandleId == InvalidHandleId)
            {
                return;
            }
            expansionWarmupPending = false;
            warmupRunning = true;

            byte[] warmupBytes = new byte[BytesPerBlock];
            warmupBytes[0] = 0xfc;
            warmupBytes[1] = 0xfd;
            warmupBytes[2] = 0xff;
            warmupBytes[3] = 0xff;
            warmupBytes[4] = 0xff;
            warmupBytes[5] = 0xff;
            warmupBytes[6] = 0xff;
            warmupBytes[7] = 0xff;
            warmupBytes[14] = 0xff;
            warmupBytes[15] = 0xff;

            expansionWarmupCompressedTexture = new Texture2D(
                BlockWidth,
                BlockHeight,
                TextureFormat.ASTC_4x4,
                false,
                false);
            expansionWarmupCompressedTexture.LoadRawTextureData(warmupBytes);
            expansionWarmupCompressedTexture.Apply(false, false);

            expansionWarmupResultTexture = new RenderTexture(
                BlockWidth,
                BlockHeight,
                0,
                RenderTextureFormat.ARGB32);
            expansionWarmupResultTexture.Create();
            if (!expansionWarmupResultTexture.IsCreated())
            {
                ReleaseExpansionWarmupResources();
                FailExpansionWarmup("ASTC expansion warmup RenderTexture creation failed.");
                return;
            }

            VRCGraphics.Blit(expansionWarmupCompressedTexture, expansionWarmupResultTexture);
            ScheduleGpuFence(expansionWarmupResultTexture, nameof(_CompleteRequestedExpansionWarmup));
        }

        // GPU完了確認後に展開warmupを成功状態へ確定する
        public void _CompleteRequestedExpansionWarmup()
        {
            if (!warmupRunning || activeExpansionWarmupHandleId == InvalidHandleId)
            {
                return;
            }
            CancelGpuFence();
            ReleaseGpuFenceMarkerTexture();
            ReleaseExpansionWarmupResources();
            CompleteExpansionWarmup();
        }

        // 指定handleの展開warmupをキャンセルする
        public bool CancelExpansionWarmup(int handleId)
        {
            if (handleId == InvalidHandleId || handleId != activeExpansionWarmupHandleId)
            {
                return false;
            }

            cancelledExpansionWarmupHandleId = handleId;
            activeExpansionWarmupHandleId = InvalidHandleId;
            expansionWarmupRequestReceiver = null;
            expansionWarmupStartedAt = 0f;
            expansionWarmupPending = false;
            warmupRunning = false;
            warmupComplete = false;
            warmupFailed = false;
            SetStatus("ASTC expansion warmup cancelled.");
            ReleaseFailedGpuResourcesWhenReadbackCompletes();
            return true;
        }

        // 指定handleの展開warmup状態を返す
        public int GetExpansionWarmupState(int handleId)
        {
            if (handleId == InvalidHandleId) return TaskStateUnknown;
            if (handleId == activeExpansionWarmupHandleId)
            {
                return warmupRunning ? TaskStateRunning : TaskStatePending;
            }
            if (handleId == completedExpansionWarmupHandleId) return TaskStateSucceeded;
            if (handleId == failedExpansionWarmupHandleId) return TaskStateFailed;
            if (handleId == cancelledExpansionWarmupHandleId) return TaskStateCancelled;
            return TaskStateUnknown;
        }

        // 指定handleの展開warmup進行段階を返す
        public int GetExpansionWarmupStage(int handleId)
        {
            if (handleId == completedExpansionWarmupHandleId) return ProgressStageComplete;
            if (handleId == activeExpansionWarmupHandleId)
            {
                return warmupRunning ? ProgressStageProcessing : ProgressStagePending;
            }
            return ProgressStageUnknown;
        }

        // 指定handleの展開warmup進捗を0から1で返す
        public float GetExpansionWarmupProgress01(int handleId)
        {
            if (handleId == completedExpansionWarmupHandleId) return 1f;
            if (handleId == activeExpansionWarmupHandleId)
            {
                if (!warmupRunning) return 0f;
                return gpuFenceMarkerQueued || gpuFenceReadbackQueued || gpuFenceReadbackPending
                    ? 0.75f
                    : 0.5f;
            }
            return -1f;
        }

        // 指定RenderTextureのGPU完了確認と継続イベントを予約する
        private void ScheduleGpuFence(RenderTexture source, string continuationEvent)
        {
            CancelGpuFence();
            if (source == null || string.IsNullOrEmpty(continuationEvent))
            {
                FailGpuFence("ASTC GPU fence source or continuation is missing.");
                return;
            }
            gpuFenceSourceTexture = source;
            gpuFenceContinuationEvent = continuationEvent;
            gpuFenceMarkerQueued = true;
            SendCustomEventDelayedFrames(nameof(_RunGpuFenceMarkerBlit), 1);
        }

        // 展開結果から完了確認用markerを生成する
        public void _RunGpuFenceMarkerBlit()
        {
            if ((!expansionPending && !warmupRunning && !failedGpuResourceReleasePending)
                || !gpuFenceMarkerQueued || gpuFenceSourceTexture == null)
            {
                return;
            }

            gpuFenceMarkerQueued = false;
            if (gpuFenceMarkerTexture == null)
            {
                gpuFenceMarkerTexture = new RenderTexture(
                    GpuFenceMarkerSize,
                    GpuFenceMarkerSize,
                    0,
                    RenderTextureFormat.ARGB32,
                    RenderTextureReadWrite.Linear);
                gpuFenceMarkerTexture.name = "IC_ASTC_ExpansionGpuFenceMarker";
                gpuFenceMarkerTexture.filterMode = FilterMode.Point;
                gpuFenceMarkerTexture.wrapMode = TextureWrapMode.Clamp;
                gpuFenceMarkerTexture.useMipMap = false;
                gpuFenceMarkerTexture.autoGenerateMips = false;
                gpuFenceMarkerTexture.Create();
            }
            if (!gpuFenceMarkerTexture.IsCreated())
            {
                FailGpuFence("ASTC GPU fence marker texture creation failed.");
                return;
            }

            VRCGraphics.Blit(gpuFenceSourceTexture, gpuFenceMarkerTexture);
            gpuFenceReadbackQueued = true;
            SendCustomEventDelayedFrames(nameof(_RunGpuFenceReadbackRequest), 1);
        }

        // 完了確認用markerの非同期readbackを要求する
        public void _RunGpuFenceReadbackRequest()
        {
            if ((!expansionPending && !warmupRunning && !failedGpuResourceReleasePending)
                || !gpuFenceReadbackQueued || gpuFenceReadbackPending || gpuFenceMarkerTexture == null)
            {
                return;
            }

            gpuFenceReadbackQueued = false;
            gpuFenceReadbackRequest = VRCAsyncGPUReadback.Request(
                gpuFenceMarkerTexture,
                0,
                0, 1,
                0, 1,
                0, 1,
                TextureFormat.RGBA32,
                this);
            gpuFenceReadbackPending = true;
            SendCustomEventDelayedFrames(nameof(_PollGpuFenceReadback), 1);
        }

        // GPU完了確認用readbackを監視し継続イベントへ進む
        public void _PollGpuFenceReadback()
        {
            if ((!expansionPending && !warmupRunning && !failedGpuResourceReleasePending) || !gpuFenceReadbackPending)
            {
                return;
            }
            if (!gpuFenceReadbackRequest.done)
            {
                SendCustomEventDelayedFrames(nameof(_PollGpuFenceReadback), 1);
                return;
            }

            gpuFenceReadbackPending = false;
            if (failedGpuResourceReleasePending)
            {
                _PollFailedGpuResourceRelease();
                return;
            }
            if (gpuFenceReadbackRequest.hasError)
            {
                FailGpuFence("ASTC GPU fence readback failed.");
                return;
            }

            string continuationEvent = gpuFenceContinuationEvent;
            CancelGpuFence();
            if (string.IsNullOrEmpty(continuationEvent))
            {
                FailGpuFence("ASTC GPU fence continuation is missing.");
                return;
            }
            SendCustomEventDelayedFrames(continuationEvent, 1);
        }

        // GPU readback完了通知を受けて保存中requestの確認を予約する
        public override void OnAsyncGpuReadbackComplete(VRCAsyncGPUReadbackRequest completedRequest)
        {
            // 保存中requestをpollする。遅延callbackを次の展開requestへ適用しない
        }

        // GPU完了確認の予約状態と参照を初期化する
        private void CancelGpuFence()
        {
            gpuFenceSourceTexture = null;
            gpuFenceMarkerQueued = false;
            gpuFenceReadbackQueued = false;
            gpuFenceReadbackPending = false;
            gpuFenceContinuationEvent = "";
        }

        // 異常終了時の未完了readbackを待って関連GPUリソースを解放する
        private void ReleaseFailedGpuResourcesWhenReadbackCompletes()
        {
            if (gpuFenceMarkerQueued && gpuFenceSourceTexture == null)
            {
                gpuFenceMarkerQueued = false;
            }

            bool fenceReadbackWaiting = gpuFenceReadbackPending && !gpuFenceReadbackRequest.done;
            if (gpuFenceMarkerQueued || gpuFenceReadbackQueued || fenceReadbackWaiting)
            {
                failedGpuResourceReleasePending = true;
                if (gpuFenceMarkerQueued)
                {
                    SendCustomEventDelayedFrames(nameof(_RunGpuFenceMarkerBlit), 1);
                }
                else if (gpuFenceReadbackQueued)
                {
                    SendCustomEventDelayedFrames(nameof(_RunGpuFenceReadbackRequest), 1);
                }
                else
                {
                    SendCustomEventDelayedFrames(nameof(_PollFailedGpuResourceRelease), 1);
                }
                return;
            }

            failedGpuResourceReleasePending = false;
            CancelGpuFence();
            ReleaseGpuFenceMarkerTexture();
            ReleaseExpansionWarmupResources();
            _ClearOutputTexture();
            FlushTerminalNotifications();
        }

        // 異常終了後のGPU完了を監視してリソース解放へ進む
        public void _PollFailedGpuResourceRelease()
        {
            if (!failedGpuResourceReleasePending)
            {
                return;
            }

            ReleaseFailedGpuResourcesWhenReadbackCompletes();
        }


        // warmupまたは展開処理をGPU完了確認失敗として終了する
        private void FailGpuFence(string message)
        {
            bool failingWarmup = warmupRunning && activeExpansionWarmupHandleId != InvalidHandleId;
            if (failingWarmup)
            {
                FailExpansionWarmup(message);
                return;
            }
            FailExpand(message);
        }

        // GPU完了確認用marker Textureを解放する
        private void ReleaseGpuFenceMarkerTexture()
        {
            if (gpuFenceMarkerTexture == null)
            {
                return;
            }
            if (gpuFenceMarkerTexture.IsCreated())
            {
                gpuFenceMarkerTexture.Release();
            }
            Destroy(gpuFenceMarkerTexture);
            gpuFenceMarkerTexture = null;
        }

        // 展開要求とwarmupのtimeoutを監視する
        private void Update()
        {
            if (activeExpansionWarmupHandleId != InvalidHandleId && expansionWarmupStartedAt > 0f
                && Time.realtimeSinceStartup - expansionWarmupStartedAt > Mathf.Max(1f, operationTimeoutSeconds))
            {
                FailExpansionWarmup("ASTC expansion warmup timed out.");
            }
            if (!expansionPending || expansionStartedAt <= 0f
                || Time.realtimeSinceStartup - expansionStartedAt <= Mathf.Max(1f, operationTimeoutSeconds))
            {
                return;
            }
            FailExpand("ASTC expansion timed out.");
        }

        // native ASTC 4x4 byte列を検証し、成功時はoutputTextureを新しいASTC Textureへ置き換える
        public void _LoadSourceBytesToTexture()
        {
            // 前回結果を破棄して状態を初期化してから入力を検証する
            expandComplete = false;
            expandFailed = false;
            sourceByteCount = 0;
            blockCountX = 0;
            blockCountY = 0;
            _ClearOutputTexture();

            // byte数の完全一致を要求し、欠損・余剰byteをGPU decoderへ渡さない
            if (!IsInputValid())
            {
                FailExpand("Invalid ASTC input.");
                return;
            }

            // linear:falseでRGBA_ASTC4X4_SRGB、linear:trueでRGBA_ASTC4X4_UNormが選ばれる
            // linear引数はbyte値を変換するものではなく、sampling時の色空間解釈を指定する
            // ARGB32 RenderTextureへBlitしないため、表示に渡した後もASTCのVRAM削減効果が残る
            // raw payload自体には寸法情報がないため、sourceWidth/sourceHeightは圧縮時の元寸法と完全一致させる
            // 端数寸法は4x4 blockへ切り上げられるが、ASTC対応と最大Texture寸法は実行端末に依存する
            Texture2D texture = new Texture2D(sourceWidth, sourceHeight, TextureFormat.ASTC_4x4, false, !encodedSrgb);
            // encoderが出力したnative 16byte/blockを並べ替えず、そのままUnityへuploadする
            texture.LoadRawTextureData(sourceBytes);
            // 圧縮blockの検証表示で補間やRepeatによる境界混入を避ける
            texture.filterMode = FilterMode.Point;
            texture.wrapMode = TextureWrapMode.Clamp;
            texture.Apply(false, false);
            outputTexture = texture;

            expandComplete = true;
            SetStatus("ASTC texture loaded. bytes=" + sourceByteCount.ToString()
                + " encodedSrgb=" + (encodedSrgb ? "1" : "0"));
            if (activeExpansionHandleId != InvalidHandleId)
            {
                CompleteRequestedExpansion();
                return;
            }
            SendCompletionEvent();
        }

        // 展開元の公開byte列参照を解除する
        public void _ClearSourceBytes()
        {
            sourceBytes = null;
            sourceByteCount = 0;
            blockCountX = 0;
            blockCountY = 0;
        }

        // 生成済みの出力Textureを破棄する
        public void _ClearOutputTexture()
        {
            // 未取得の結果だけがライブラリ所有。GPU処理中は外部から解放できない
            if (IsBusy) return;
            Texture result = outputTexture;
            outputTexture = null;
            if (expansionResultTexture == result) expansionResultTexture = null;
            if (result == null) return;
            Destroy(result);
        }

        // encoder側と完全に同じ切り上げ計算を使い、byte[]のimport/exportで長さがずれないようにする
        public int GetCompressedByteCount(int width, int height)
        {
            if (width <= 0 || height <= 0)
            {
                return 0;
            }

            long byteCount = (long)GetBlockCountX(width) * (long)GetBlockCountY(height) * BytesPerBlock;
            return byteCount > 0L && byteCount <= int.MaxValue ? (int)byteCount : 0;
        }

        // 入力byte列と画像寸法がASTC形式として妥当かを検証する
        private bool IsInputValid()
        {
            // null、画像寸法、4x4 block換算後のbyte数を順に検証する
            if (sourceBytes == null)
            {
                return false;
            }

            if (sourceWidth <= 0 || sourceHeight <= 0
                || sourceWidth > MaxExpansionTextureDimension
                || sourceHeight > MaxExpansionTextureDimension
                || (long)sourceWidth * (long)sourceHeight > MaxExpansionPixelCount)
            {
                return false;
            }

            // 端数pixelを含む画像もblock単位で切り上げるため、単純なwidth*heightでは計算しない
            sourceByteCount = GetCompressedByteCount(sourceWidth, sourceHeight);
            if (sourceByteCount <= 0)
            {
                return false;
            }
            blockCountX = GetBlockCountX(sourceWidth);
            blockCountY = GetBlockCountY(sourceHeight);
            return sourceBytes.Length == sourceByteCount;
        }

        // 画像幅から横方向のASTCブロック数を求める
        private int GetBlockCountX(int width)
        {
            // 整数除算でceil(width / 4)を求める
            return (int)(((long)width + BlockWidth - 1L) / BlockWidth);
        }

        // 画像高さから縦方向のASTCブロック数を求める
        private int GetBlockCountY(int height)
        {
            return (int)(((long)height + BlockHeight - 1L) / BlockHeight);
        }

        // 圧縮Textureをそのまま結果として保持し、要求元へ通知する
        private void CompleteRequestedExpansion()
        {
            if (!expansionPending || activeExpansionHandleId == InvalidHandleId || outputTexture == null)
            {
                return;
            }
            // 表示用の補間設定を維持し、非圧縮RenderTextureへの転写は行わない
            outputTexture.filterMode = FilterMode.Bilinear;
            expansionResultTexture = outputTexture;
            expandComplete = true;
            expandFailed = false;
            expansionPending = false;
            expansionStartedAt = 0f;
            completedExpansionHandleId = activeExpansionHandleId;
            activeExpansionHandleId = InvalidHandleId;
            SendCompletionEvent();
        }

        // 展開処理を失敗状態にしてGPUリソース解放と通知を行う
        private void FailExpand(string message)
        {
            expansionPending = false;
            expansionStartedAt = 0f;
            expandComplete = false;
            expandFailed = true;
            if (activeExpansionHandleId != InvalidHandleId)
            {
                failedExpansionHandleId = activeExpansionHandleId;
                activeExpansionHandleId = InvalidHandleId;
            }
            SetStatus("Failed: " + message);
            // cleanup待機を先に確定し、失敗eventから同じライブラリオブジェクトが再入されないようにする
            ReleaseFailedGpuResourcesWhenReadbackCompletes();
            SendFailedEvent();
        }

        // 外部参照用の状態messageを更新する
        private void SetStatus(string value)
        {
            status = value;
        }

        // 展開成功イベントを要求元または設定済み受信先へ送る
        private void SendCompletionEvent()
        {
            if (expansionRequestReceiver != null)
            {
                UdonBehaviour receiver = expansionRequestReceiver;
                expansionRequestReceiver = null;
                receiver.SendCustomEvent(ExpansionSucceededEventName);
                return;
            }
            SendConfiguredEvent(completionEventName);
        }

        // 展開失敗イベントを要求元または設定済み受信先へ送る
        private void SendFailedEvent()
        {
            if (failedGpuResourceReleasePending) { failureNotificationPending = true; return; }
            failureNotificationPending = false;
            if (expansionRequestReceiver != null)
            {
                UdonBehaviour receiver = expansionRequestReceiver;
                expansionRequestReceiver = null;
                receiver.SendCustomEvent(ExpansionFailedEventName);
                return;
            }
            SendConfiguredEvent(failedEventName);
        }

        // 展開warmupを成功状態にして関連GPUリソースを解放する
        private void CompleteExpansionWarmup()
        {
            if (activeExpansionWarmupHandleId == InvalidHandleId)
            {
                return;
            }

            completedExpansionWarmupHandleId = activeExpansionWarmupHandleId;
            activeExpansionWarmupHandleId = InvalidHandleId;
            expansionWarmupStartedAt = 0f;
            expansionWarmupPending = false;
            warmupRunning = false;
            warmupComplete = true;
            warmupFailed = false;
            CancelGpuFence();
            ReleaseGpuFenceMarkerTexture();
            SetStatus("ASTC expansion warmup complete.");
            if (expansionWarmupRequestReceiver != null)
            {
                UdonBehaviour receiver = expansionWarmupRequestReceiver;
                expansionWarmupRequestReceiver = null;
                receiver.SendCustomEvent(ExpansionWarmupSucceededEventName);
            }
        }

        // 展開warmupを失敗状態にして後処理と通知を行う
        private void FailExpansionWarmup(string message)
        {
            if (activeExpansionWarmupHandleId != InvalidHandleId)
            {
                failedExpansionWarmupHandleId = activeExpansionWarmupHandleId;
                activeExpansionWarmupHandleId = InvalidHandleId;
            }
            expansionWarmupStartedAt = 0f;
            expansionWarmupPending = false;
            warmupRunning = false;
            warmupComplete = false;
            warmupFailed = true;
            SetStatus("Failed: " + message);
            ReleaseFailedGpuResourcesWhenReadbackCompletes();
            if (expansionWarmupRequestReceiver != null)
            {
                UdonBehaviour receiver = expansionWarmupRequestReceiver;
                expansionWarmupRequestReceiver = null;
                receiver.SendCustomEvent(ExpansionWarmupFailedEventName);
            }
        }

        // 展開warmupで生成したTextureとRenderTextureを解放する
        private void ReleaseExpansionWarmupResources()
        {
            if (expansionWarmupCompressedTexture != null)
            {
                Destroy(expansionWarmupCompressedTexture);
                expansionWarmupCompressedTexture = null;
            }
            if (expansionWarmupResultTexture != null)
            {
                expansionWarmupResultTexture.Release();
                Destroy(expansionWarmupResultTexture);
                expansionWarmupResultTexture = null;
            }
        }

        // 次の展開handle IDを生成する
        private int GenerateExpansionHandleId()
        {
            nextExpansionHandleId++;
            if (nextExpansionHandleId <= 0)
            {
                nextExpansionHandleId = 1;
            }
            return nextExpansionHandleId;
        }

        // 次の展開warmup handle IDを生成する
        private int GenerateExpansionWarmupHandleId()
        {
            nextExpansionWarmupHandleId++;
            if (nextExpansionWarmupHandleId <= 0)
            {
                nextExpansionWarmupHandleId = 1;
            }
            return nextExpansionWarmupHandleId;
        }

        // 設定済み受信先へ指定名のcustom eventを送る
        private void SendConfiguredEvent(string eventName)
        {
            if (completionEventReceiver == null || eventName == null || eventName.Length == 0)
            {
                return;
            }

            // Udon VMで利用可能なSendCustomEventを使い、delegateやC# eventには依存しない
            completionEventReceiver.SendCustomEvent(eventName);
        }

        // 取り出し後は呼び側が解放する。次の要求やライブラリ終了で破棄されない
        public Texture TakeExpansionResult(int handleId)
        {
            if (handleId == InvalidHandleId || handleId != completedExpansionHandleId) return null;
            Texture result = expansionResultTexture;
            expansionResultTexture = null;
            if (outputTexture == result) outputTexture = null;
            return result;
        }

        private void FlushTerminalNotifications()
        {
            if (failedGpuResourceReleasePending) return;
            if (failureNotificationPending) SendFailedEvent();
            if (cancellationNotificationPending)
            {
                cancellationNotificationPending = false;
                UdonBehaviour receiver = cancellationReceiver;
                cancellationReceiver = null;
                if (receiver != null) receiver.SendCustomEvent("_HandleAstcExpandCancelled");
            }
            if (disposalRequested)
            {
                _ClearOutputTexture();
                sourceBytes = null;
                disposed = true;
            }
        }

        // Destroy前に呼び、IsDisposedを待つ。待機中のcomponentを無効化しない
        public void _Dispose()
        {
            if (disposalRequested) return;
            disposalRequested = true;
            if (activeExpansionHandleId != InvalidHandleId) CancelExpansion(activeExpansionHandleId);
            if (activeExpansionWarmupHandleId != InvalidHandleId) CancelExpansionWarmup(activeExpansionWarmupHandleId);
            ReleaseFailedGpuResourcesWhenReadbackCompletes();
            FlushTerminalNotifications();
        }

        private void OnDestroy()
        {
            CancelGpuFence();
            ReleaseGpuFenceMarkerTexture();
            ReleaseExpansionWarmupResources();
            if (outputTexture != null) Destroy(outputTexture);
        }
    }
}
