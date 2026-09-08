// ASTCの再調整前に保持した候補と更新候補を比較し、再現誤差の小さい候補を残すシェーダー
// 構成: 1つのPassで構成し、Astc4x4CompressCommon.cgincを読み込んで共通の頂点処理・補助関数を利用する
Shader "HDAssets/IC/ASTC/ASTC4x4SelectPreservedBlit"
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
            Name "SelectPreserved"
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment fragSelectPreserved
            ENDCG
        }
    }
    Fallback Off
}
