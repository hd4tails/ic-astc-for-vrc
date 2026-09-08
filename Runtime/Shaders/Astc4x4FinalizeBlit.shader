// 評価済み候補から各ブロックの最良候補を選び、1ブロック16バイトのASTCデータへ格納するシェーダー
// 構成: 2つのPassで構成し、Astc4x4CompressCommon.cgincを読み込んで共通の頂点処理・補助関数を利用する
// フラグメント関数はfragBestCandidate、fragPackBytesに分かれている
Shader "HDAssets/IC/ASTC/ASTC4x4FinalizeBlit"
{
    Properties
    {
        // 現在のBlitで基準入力として読むTexture
        _MainTex ("Source", 2D) = "white" {}
        // 圧縮候補の評価対象となる入力画像Texture
        _SourceTex ("Source Texture", 2D) = "white" {}
        // 現在評価している圧縮候補を保持するTexture
        _CandidateTex ("Candidate Texture", 2D) = "black" {}
        // 再調整前の初期候補を保持するTexture
        _OriginalCandidateTex ("Original Candidate Texture", 2D) = "black" {}
        // 安定したblock modeとして保持した候補Texture
        _StableCandidateTex ("Stable Candidate Texture", 2D) = "black" {}
        // 比較対象となる別系列の候補Texture
        _AlternateCandidateTex ("Alternate Candidate Texture", 2D) = "black" {}
        // 現在までの最良候補を保持するTexture
        _BestCandidateTex ("Best Candidate Texture", 2D) = "black" {}
        // 前段までの最良候補を保持するTexture
        _PreviousBestCandidateTex ("Previous Best Candidate Texture", 2D) = "black" {}
        // 入力幅
        _SourceWidth ("Source Width", Float) = 512
        // 入力高さ
        _SourceHeight ("Source Height", Float) = 512
        // 出力幅
        _OutputWidth ("Output Width", Float) = 512
        // 出力高さ
        _OutputHeight ("Output Height", Float) = 128
        // 候補Texture全体の幅
        _CandidateOutputWidth ("Candidate Output Width", Float) = 2048
        // 最良候補Textureの幅
        _BestOutputWidth ("Best Output Width", Float) = 384
        // 符号化するRGB値をsRGB領域として扱うかを示すフラグ
        _EncodeSrgb ("Encode sRGB", Float) = 0
        // 入力TextureがsRGB領域の値を保持しているかを示すフラグ
        _SourceTextureSrgb ("Source Texture sRGB", Float) = 0
        // ASTCのdual-plane候補を評価対象に含めるかを示すフラグ
        _EnableDualPlane ("Enable Dual Plane", Float) = 1
        // このPassが担当する候補バッチの開始位置
        _CandidateBatchOffset ("Candidate Batch Offset", Float) = 0
        // 前段までの最良候補が利用可能かを示すフラグ
        _HasPreviousBest ("Has Previous Best", Float) = 0
        // エンドポイントを再適合させるASTC block mode
        _FitBlockMode ("Fit Block Mode", Float) = 0
    }


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        Cull Off ZWrite Off ZTest Always

        CGINCLUDE
        #pragma target 3.5
        #include "Astc4x4CompressCommon.cginc"
        ENDCG

        Pass
        {
            Name "BestCandidate"
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment fragBestCandidate
            ENDCG
        }

        Pass
        {
            Name "PackBytes"
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment fragPackBytes
            ENDCG
        }
    }

    Fallback Off
}
