#include "UnityCG.cginc"

// 圧縮候補の評価対象となる入力画像Texture
sampler2D _SourceTex;
// 現在評価している圧縮候補を保持するTexture
sampler2D _CandidateTex;
// 再調整前の初期候補を保持するTexture
sampler2D _OriginalCandidateTex;
// 安定したblock modeとして保持した候補Texture
sampler2D _StableCandidateTex;
// 比較対象となる別系列の候補Texture
sampler2D _AlternateCandidateTex;
// 現在までの最良候補を保持するTexture
sampler2D _BestCandidateTex;
// 前段までの最良候補を保持するTexture
sampler2D _PreviousBestCandidateTex;
// 入力幅
float _SourceWidth;
// 入力高さ
float _SourceHeight;
// 出力幅
float _OutputWidth;
// 出力高さ
float _OutputHeight;
// 候補Texture全体の幅
float _CandidateOutputWidth;
// 最良候補Textureの幅
float _BestOutputWidth;
// 符号化するRGB値をsRGB領域として扱うかを示すフラグ
float _EncodeSrgb;
// 入力TextureがsRGB領域の値を保持しているかを示すフラグ
float _SourceTextureSrgb;
// ASTCのdual-plane候補を評価対象に含めるかを示すフラグ
float _EnableDualPlane;
// このPassが担当する候補バッチの開始位置
float _CandidateBatchOffset;
// 前段までの最良候補が利用可能かを示すフラグ
float _HasPreviousBest;
// エンドポイントを再適合させるASTC block mode
float _FitBlockMode;

// ASTC block modeとrefine modeは規格bit列へ直結する固定値。変更時はpacking配置とvalidatorも同時に更新する
static const int ASTC_MODE_3X2_QUANT16 = 0x38E;
// 3×2 weight grid・dual-plane・QUANT_8を表すASTC block mode値
static const int ASTC_MODE_3X2_DUAL_QUANT8 = 0x59F;
// 4×4 weight grid・single-plane・QUANT_4を表すASTC block mode値
static const int ASTC_MODE_4X4_QUANT4 = 0x042;
// 1つの候補生成Passで処理するASTC候補数
static const int ASTC_CANDIDATE_BATCH_SIZE = 2;
// 1つの候補生成Passで処理するASTC候補数
static const int ASTC_CANDIDATE_ENDPOINT_PIXELS = ASTC_CANDIDATE_BATCH_SIZE * 2;
// 候補比較Textureで最良候補に割り当てるpixel数
static const int ASTC_BEST_PIXELS = 3;
// 3×2 weight grid候補を再調整する処理種別
static const int ASTC_REFINE_3X2 = 0;
// 4×4 weight grid候補を再調整する処理種別
static const int ASTC_REFINE_4X4 = 1;
// 再調整前の候補を保持する処理種別
static const int ASTC_REFINE_PRESERVE = 2;
// alphaを別planeで再調整する処理種別
static const int ASTC_REFINE_DUAL_ALPHA = 3;

struct AppData
{
    // Object空間の入力頂点位置
    float4 vertex : POSITION;
    // 頂点処理で受け渡すUV座標
    float2 uv : TEXCOORD0;
};

struct Varyings
{
    // clip空間へ変換した頂点位置
    float4 vertex : SV_POSITION;
    // 頂点処理で受け渡すUV座標
    float2 uv : TEXCOORD0;
};

Varyings vert(AppData v)
{
    // 各pass共通の全画面Blit頂点処理。pixel計算はfragment側のOutputPixel()へ集約する
    Varyings o;
    o.vertex = UnityObjectToClipPos(v.vertex);
    o.uv = v.uv;
    return o;
}

int2 OutputPixel(float2 uv, float width, float height)
{
    // BlitのUVを整数pixel座標へ戻し、端の丸め誤差で作業面外を参照しないようclampする
    int2 p = (int2)floor(uv * float2(width, height));
    p.x = clamp(p.x, 0, (int)width - 1);
    p.y = clamp(p.y, 0, (int)height - 1);
    return p;
}

float3 LinearToSrgb(float3 color)
{
    // IEC sRGBの区分関数。pow()へ負値を渡さないようhigh側をmax(0)で保護する
    float3 low = color * 12.92;
    float3 high = 1.055 * pow(max(color, 0.0), 0.416666667) - 0.055;
    return saturate(lerp(high, low, step(color, 0.0031308)));
}

float3 SrgbToLinear(float3 color)
{
    // sRGB値をlinearへ戻す区分関数。ASTCへ格納する色領域が入力samplingと異なる場合だけ使用する
    float3 low = color / 12.92;
    float3 high = pow(max((color + 0.055) / 1.055, 0.0), 2.4);
    return saturate(lerp(high, low, step(color, 0.04045)));
}

bool SourceSampleIsSrgb()
{
    // LinearプロジェクトではUnityがsRGB Textureをsampling時にlinear化済みなのでfalseになる
    // Gammaプロジェクトでは自動変換されないため、呼び出し側が渡したimport色空間を参照する
    #if defined(UNITY_COLORSPACE_GAMMA)
    return _SourceTextureSrgb > 0.5;
    #else
    return false;
    #endif
}

float3 SourceColorForAstcEncoding(float3 color)
{
    // Shaderが受け取った値の色領域と、ASTC byte列へ格納したい色領域を一致させる
    bool sourceIsSrgb = SourceSampleIsSrgb();
    // 符号化するRGB値をsRGB領域として扱うかを示すフラグ
    bool encodeIsSrgb = _EncodeSrgb > 0.5;
    if (sourceIsSrgb == encodeIsSrgb)
    {
        return saturate(color);
    }

    return encodeIsSrgb ? LinearToSrgb(color) : SrgbToLinear(color);
}

float4 SourceColorAtLocal(int blockX, int blockY, int localX, int localY)
{
    // 元画像寸法が4の倍数でない端blockは、最後のtexelを複製して4x4を埋める
    // wrap mode任せにせず座標を明示clampし、platform差を避ける
    int srcX = min(blockX * 4 + localX, (int)_SourceWidth - 1);
    int srcY = min(blockY * 4 + localY, (int)_SourceHeight - 1);
    // 入力幅
    float2 uv = (float2(srcX, srcY) + 0.5) / float2(_SourceWidth, _SourceHeight);
    float4 color = saturate(tex2Dlod(_SourceTex, float4(uv, 0.0, 0.0)));
    color.rgb = SourceColorForAstcEncoding(color.rgb);
    return color;
}

float Component(float4 color, int channel)
{
    // 動的channel選択を配列なしで行い、Udon/Quest向けShader compilerでも単純な分岐へ展開できる形にする
    if (channel == 0) return color.r;
    if (channel == 1) return color.g;
    if (channel == 2) return color.b;
    return color.a;
}

float Luma(float3 color)
{
    // Rec.709係数で輝度方向のendpoint候補を作る
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float4 EncodedEndpointColor(float4 color)
{
    // 現在のdirect endpoint modeは各channel 8bitなので、評価時点から実際の復元値へ量子化して誤差を測る
    return round(saturate(color) * 255.0) * 0.00392156862;
}

void OrderDirectEndpoints(inout float4 endpoint0, inout float4 endpoint1)
{
    // LDR RGBA direct modeはRGB合計がendpoint0 > endpoint1だとblue-contractionとして解釈される
    // 意図しないdecode modeへ入らないよう、endpointの順序を必ず正規化する
    if (endpoint0.r + endpoint0.g + endpoint0.b > endpoint1.r + endpoint1.g + endpoint1.b)
    {
        float4 tmp = endpoint0;
        endpoint0 = endpoint1;
        endpoint1 = tmp;
    }
}

int ColorByte(float value)
{
    // endpoint channelを規格へ格納する0..255へ丸める
    return (int)round(saturate(value) * 255.0);
}

void GetColorBounds(int blockX, int blockY, out float4 minColor, out float4 maxColor)
{
    // 4x4 block内のRGBA各channelの最小値・最大値を求め、複数の候補生成で共用する
    float4 firstColor = SourceColorAtLocal(blockX, blockY, 0, 0);
    minColor = firstColor;
    maxColor = firstColor;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, x, y);
            minColor = min(minColor, color);
            maxColor = max(maxColor, color);
        }
    }
}

void GetOrderedEndpoints(int blockX, int blockY, out float4 endpoint0, out float4 endpoint1)
{
    // RGBA bounding-boxの対角方向へ全texelを射影し、最小/最大位置の実texelをendpoint候補にする
    float4 minColor;
    float4 maxColor;
    GetColorBounds(blockX, blockY, minColor, maxColor);

    float4 direction = maxColor - minColor;
    float directionLengthSquared = dot(direction, direction);
    endpoint0 = SourceColorAtLocal(blockX, blockY, 0, 0);
    endpoint1 = endpoint0;
    if (directionLengthSquared <= 0.000001)
    {
        return;
    }

    float minProjection = dot(endpoint0 - minColor, direction);
    float maxProjection = minProjection;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, x, y);
            float projection = dot(color - minColor, direction);
            if (projection < minProjection)
            {
                endpoint0 = color;
                minProjection = projection;
            }
            if (projection > maxProjection)
            {
                endpoint1 = color;
                maxProjection = projection;
            }
        }
    }
}

void GetRgbProjectionEndpoints(int blockX, int blockY, out float4 endpoint0, out float4 endpoint1)
{
    // alphaの変動にRGB endpoint方向が引っ張られないよう、RGBだけでbounding-box対角へ射影する候補
    endpoint0 = SourceColorAtLocal(blockX, blockY, 0, 0);
    endpoint1 = endpoint0;

    float4 minColor;
    float4 maxColor;
    GetColorBounds(blockX, blockY, minColor, maxColor);

    float3 direction = maxColor.rgb - minColor.rgb;
    float directionLengthSquared = dot(direction, direction);
    if (directionLengthSquared <= 0.000001)
    {
        return;
    }

    float minProjection = dot(endpoint0.rgb - minColor.rgb, direction);
    float maxProjection = minProjection;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, x, y);
            float projection = dot(color.rgb - minColor.rgb, direction);
            if (projection < minProjection)
            {
                endpoint0 = color;
                minProjection = projection;
            }
            if (projection > maxProjection)
            {
                endpoint1 = color;
                maxProjection = projection;
            }
        }
    }
}

void GetLumaEndpoints(int blockX, int blockY, out float4 endpoint0, out float4 endpoint1)
{
    // 最暗/最明の実texelを選ぶ。空や地面のように主に明度が変化するblockに有効
    endpoint0 = SourceColorAtLocal(blockX, blockY, 0, 0);
    endpoint1 = endpoint0;
    float minLuma = Luma(endpoint0.rgb);
    float maxLuma = minLuma;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, x, y);
            float luma = Luma(color.rgb);
            if (luma < minLuma)
            {
                endpoint0 = color;
                minLuma = luma;
            }
            if (luma > maxLuma)
            {
                endpoint1 = color;
                maxLuma = luma;
            }
        }
    }
}

int DominantRgbChannel(float4 minColor, float4 maxColor)
{
    // block内でrangeが最大のRGB channelを返す
    float3 range = maxColor.rgb - minColor.rgb;
    if (range.r >= range.g && range.r >= range.b) return 0;
    if (range.g >= range.b) return 1;
    return 2;
}

void GetDominantRgbChannelEndpoints(int blockX, int blockY, out float4 endpoint0, out float4 endpoint1)
{
    // 最大range channelの最小/最大texelを使い、単一色軸のgradientに強い候補を作る
    endpoint0 = SourceColorAtLocal(blockX, blockY, 0, 0);
    endpoint1 = endpoint0;

    float4 minColor;
    float4 maxColor;
    GetColorBounds(blockX, blockY, minColor, maxColor);
    int channel = DominantRgbChannel(minColor, maxColor);
    float minValue = Component(endpoint0, channel);
    float maxValue = minValue;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, x, y);
            float value = Component(color, channel);
            if (value < minValue)
            {
                endpoint0 = color;
                minValue = value;
            }
            if (value > maxValue)
            {
                endpoint1 = color;
                maxValue = value;
            }
        }
    }
}

void GetRgbPcaEndpoints(int blockX, int blockY, out float4 endpoint0, out float4 endpoint1)
{
    // RGB共分散行列へpower iterationを1回適用し、主要な色変化軸の両端texelを候補にする
    // 完全な固有値分解はShader負荷が高いため行わず、bounding-box対角を初期軸にして近似する
    endpoint0 = SourceColorAtLocal(blockX, blockY, 0, 0);
    endpoint1 = endpoint0;

    float4 minColor = endpoint0;
    float4 maxColor = endpoint0;
    float3 mean = 0.0;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, x, y);
            minColor = min(minColor, color);
            maxColor = max(maxColor, color);
            mean += color.rgb;
        }
    }
    mean *= 0.0625;

    float xx = 0.0;
    float xy = 0.0;
    float xz = 0.0;
    float yy = 0.0;
    float yz = 0.0;
    float zz = 0.0;
    for (int covY = 0; covY < 4; covY++)
    {
        for (int covX = 0; covX < 4; covX++)
        {
            float3 centered = SourceColorAtLocal(blockX, blockY, covX, covY).rgb - mean;
            xx += centered.x * centered.x;
            xy += centered.x * centered.y;
            xz += centered.x * centered.z;
            yy += centered.y * centered.y;
            yz += centered.y * centered.z;
            zz += centered.z * centered.z;
        }
    }

    float3 axis = maxColor.rgb - minColor.rgb;
    if (dot(axis, axis) <= 0.000001)
    {
        return;
    }

    axis = normalize(axis);
    float3 nextAxis = float3(
        xx * axis.x + xy * axis.y + xz * axis.z,
        xy * axis.x + yy * axis.y + yz * axis.z,
        xz * axis.x + yz * axis.y + zz * axis.z);
    if (dot(nextAxis, nextAxis) > 0.000001)
    {
        axis = normalize(nextAxis);
    }

    float minProjection = dot(endpoint0.rgb - mean, axis);
    float maxProjection = minProjection;
    for (int projY = 0; projY < 4; projY++)
    {
        for (int projX = 0; projX < 4; projX++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, projX, projY);
            float projection = dot(color.rgb - mean, axis);
            if (projection < minProjection)
            {
                endpoint0 = color;
                minProjection = projection;
            }
            if (projection > maxProjection)
            {
                endpoint1 = color;
                maxProjection = projection;
            }
        }
    }
}

void GetOutsetEndpoints(float4 source0, float4 source1, out float4 endpoint0, out float4 endpoint1)
{
    // weight量子化でgradient端が内側へ縮む場合を補うため、候補rangeを両側へ8%広げる
    float4 delta = source1 - source0;
    endpoint0 = saturate(source0 - delta * 0.08);
    endpoint1 = saturate(source1 + delta * 0.08);
}

void GetOutlierEndpoints(int blockX, int blockY, out float4 endpoint0, out float4 endpoint1)
{
    // 平均色から最も離れた1texelと、残り15texelの平均をendpointにする
    // 小さな星やハイライトなど孤立した高contrast detailを保持するための候補
    float4 mean = 0.0;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            mean += SourceColorAtLocal(blockX, blockY, x, y);
        }
    }
    mean *= 0.0625;

    int outlierX = 0;
    int outlierY = 0;
    float outlierDistance = -1.0;
    for (int searchY = 0; searchY < 4; searchY++)
    {
        for (int searchX = 0; searchX < 4; searchX++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, searchX, searchY);
            float3 delta = color.rgb - mean.rgb;
            float distance = dot(delta, delta);
            if (distance > outlierDistance)
            {
                outlierDistance = distance;
                outlierX = searchX;
                outlierY = searchY;
            }
        }
    }

    endpoint1 = SourceColorAtLocal(blockX, blockY, outlierX, outlierY);
    endpoint0 = 0.0;
    float backgroundWeight = 0.0;
    for (int sumY = 0; sumY < 4; sumY++)
    {
        for (int sumX = 0; sumX < 4; sumX++)
        {
            float weight = (sumX == outlierX && sumY == outlierY) ? 0.0 : 1.0;
            endpoint0 += SourceColorAtLocal(blockX, blockY, sumX, sumY) * weight;
            backgroundWeight += weight;
        }
    }

    endpoint0 = backgroundWeight > 0.5 ? endpoint0 / backgroundWeight : mean;
}

void GetOutlierPairEndpoints(int blockX, int blockY, out float4 endpoint0, out float4 endpoint1)
{
    // 平均色から遠い2texelの平均と、残り14texelの平均をendpointにする
    // 1pixelだけでなく細い線や2pixelのdetailがあるblockを候補へ含める
    float4 mean = 0.0;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            mean += SourceColorAtLocal(blockX, blockY, x, y);
        }
    }
    mean *= 0.0625;

    int outlier0X = 0;
    int outlier0Y = 0;
    int outlier1X = 1;
    int outlier1Y = 0;
    float outlier0Distance = -1.0;
    float outlier1Distance = -1.0;
    for (int searchY = 0; searchY < 4; searchY++)
    {
        for (int searchX = 0; searchX < 4; searchX++)
        {
            float4 color = SourceColorAtLocal(blockX, blockY, searchX, searchY);
            float3 delta = color.rgb - mean.rgb;
            float distance = dot(delta, delta);
            if (distance > outlier0Distance)
            {
                outlier1Distance = outlier0Distance;
                outlier1X = outlier0X;
                outlier1Y = outlier0Y;
                outlier0Distance = distance;
                outlier0X = searchX;
                outlier0Y = searchY;
            }
            else if (distance > outlier1Distance)
            {
                outlier1Distance = distance;
                outlier1X = searchX;
                outlier1Y = searchY;
            }
        }
    }

    float4 outlier0 = SourceColorAtLocal(blockX, blockY, outlier0X, outlier0Y);
    float4 outlier1 = SourceColorAtLocal(blockX, blockY, outlier1X, outlier1Y);
    endpoint1 = (outlier0 + outlier1) * 0.5;
    endpoint0 = 0.0;
    float backgroundWeight = 0.0;
    for (int sumY = 0; sumY < 4; sumY++)
    {
        for (int sumX = 0; sumX < 4; sumX++)
        {
            float isOutlier = ((sumX == outlier0X && sumY == outlier0Y) || (sumX == outlier1X && sumY == outlier1Y)) ? 1.0 : 0.0;
            float weight = 1.0 - isOutlier;
            endpoint0 += SourceColorAtLocal(blockX, blockY, sumX, sumY) * weight;
            backgroundWeight += weight;
        }
    }

    endpoint0 = backgroundWeight > 0.5 ? endpoint0 / backgroundWeight : mean;
}

void GetCandidateEndpointsBatch0(int blockX, int blockY, int candidateIndex, out float4 endpoint0, out float4 endpoint1)
{
    endpoint0 = 0.0;
    endpoint1 = 0.0;
    if (candidateIndex == 0) GetOrderedEndpoints(blockX, blockY, endpoint0, endpoint1);
    else if (candidateIndex == 1) GetRgbProjectionEndpoints(blockX, blockY, endpoint0, endpoint1);
    else if (candidateIndex == 2) GetLumaEndpoints(blockX, blockY, endpoint0, endpoint1);
    else GetDominantRgbChannelEndpoints(blockX, blockY, endpoint0, endpoint1);
}

void GetCandidateEndpointsBatch1(int blockX, int blockY, int candidateIndex, out float4 endpoint0, out float4 endpoint1)
{
    endpoint0 = 0.0;
    endpoint1 = 0.0;
    if (candidateIndex == 0)
    {
        GetRgbPcaEndpoints(blockX, blockY, endpoint0, endpoint1);
        return;
    }

    float4 base0;
    float4 base1;
    if (candidateIndex == 1) GetOrderedEndpoints(blockX, blockY, base0, base1);
    else if (candidateIndex == 2) GetRgbProjectionEndpoints(blockX, blockY, base0, base1);
    else GetDominantRgbChannelEndpoints(blockX, blockY, base0, base1);
    GetOutsetEndpoints(base0, base1, endpoint0, endpoint1);
}

void GetCandidateEndpointsBatch2(int blockX, int blockY, int candidateIndex, out float4 endpoint0, out float4 endpoint1)
{
    endpoint0 = 0.0;
    endpoint1 = 0.0;
    if (candidateIndex == 1)
    {
        GetOutlierEndpoints(blockX, blockY, endpoint0, endpoint1);
        return;
    }
    if (candidateIndex == 2)
    {
        GetOutlierPairEndpoints(blockX, blockY, endpoint0, endpoint1);
        return;
    }

    float4 base0;
    float4 base1;
    if (candidateIndex == 0) GetLumaEndpoints(blockX, blockY, base0, base1);
    else GetOutlierPairEndpoints(blockX, blockY, base0, base1);
    GetOutsetEndpoints(base0, base1, endpoint0, endpoint1);
}

float4 ReadCandidateEndpoint(int blockX, int candidateIndex, int endpointIndex, int blockY)
{
    // Pass 0の横配置は「block → candidate → endpoint」の順。Point samplingで値をそのまま読む
    int pixelX = blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS + candidateIndex * 2 + endpointIndex;
    // 候補Texture全体の幅
    float2 uv = (float2(pixelX, blockY) + 0.5) / float2(_CandidateOutputWidth, _OutputHeight);
    return saturate(tex2Dlod(_CandidateTex, float4(uv, 0.0, 0.0)));
}

float4 ReadBestPixel(int blockX, int localIndex, int blockY)
{
    // Pass 2は1 blockにつきendpoint0、endpoint1、mode情報の3pixelを並べる
    int pixelX = blockX * ASTC_BEST_PIXELS + localIndex;
    // 最良候補Textureの幅
    float2 uv = (float2(pixelX, blockY) + 0.5) / float2(_BestOutputWidth, _OutputHeight);
    return saturate(tex2Dlod(_BestCandidateTex, float4(uv, 0.0, 0.0)));
}

float4 ReadOriginalCandidateEndpoint(int blockX, int candidateIndex, int endpointIndex, int blockY)
{
    int pixelX = blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS + candidateIndex * 2 + endpointIndex;
    // 候補Texture全体の幅
    float2 uv = (float2(pixelX, blockY) + 0.5) / float2(_CandidateOutputWidth, _OutputHeight);
    return saturate(tex2Dlod(_OriginalCandidateTex, float4(uv, 0.0, 0.0)));
}

float4 ReadStableCandidateEndpoint(int blockX, int candidateIndex, int endpointIndex, int blockY)
{
    int pixelX = blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS + candidateIndex * 2 + endpointIndex;
    // 候補Texture全体の幅
    float2 uv = (float2(pixelX, blockY) + 0.5) / float2(_CandidateOutputWidth, _OutputHeight);
    return tex2Dlod(_StableCandidateTex, float4(uv, 0.0, 0.0));
}

float4 ReadAlternateCandidateEndpoint(int blockX, int candidateIndex, int endpointIndex, int blockY)
{
    int pixelX = blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS + candidateIndex * 2 + endpointIndex;
    // 候補Texture全体の幅
    float2 uv = (float2(pixelX, blockY) + 0.5) / float2(_CandidateOutputWidth, _OutputHeight);
    return tex2Dlod(_AlternateCandidateTex, float4(uv, 0.0, 0.0));
}

float4 ReadPreviousBestPixel(int blockX, int localIndex, int blockY)
{
    int pixelX = blockX * ASTC_BEST_PIXELS + localIndex;
    // 最良候補Textureの幅
    float2 uv = (float2(pixelX, blockY) + 0.5) / float2(_BestOutputWidth, _OutputHeight);
    return tex2Dlod(_PreviousBestCandidateTex, float4(uv, 0.0, 0.0));
}

int WeightGridWidth(int blockMode)
{
    // 採用modeからweight grid寸法を復元する。dual-planeも各planeは3x2 grid
    return blockMode == ASTC_MODE_4X4_QUANT4 ? 4 : 3;
}

int WeightGridHeight(int blockMode)
{
    // 4x4 mode以外は3x2 gridなので高さ2
    return blockMode == ASTC_MODE_4X4_QUANT4 ? 4 : 2;
}

int WeightQuantMax(int blockMode)
{
    // QUANT_8/16/4の量子化index上限。dual-planeは2 plane分を同じbit budgetへ詰めるためQUANT_8になる
    if (blockMode == ASTC_MODE_3X2_DUAL_QUANT8) return 7;
    return blockMode == ASTC_MODE_3X2_QUANT16 ? 15 : 3;
}

int UnquantizedWeight(int blockMode, int quantizedWeight)
{
    // ASTC規格の量子化indexを補間用0..64 weightへ展開する固定table
    // 単純な等間隔計算では規格のunquantization値と一致しないため、値を明示している
    int unquantizedWeight = 64;

    if (blockMode == ASTC_MODE_3X2_DUAL_QUANT8)
    {
        if (quantizedWeight <= 0) unquantizedWeight = 0;
        else if (quantizedWeight == 1) unquantizedWeight = 9;
        else if (quantizedWeight == 2) unquantizedWeight = 18;
        else if (quantizedWeight == 3) unquantizedWeight = 27;
        else if (quantizedWeight == 4) unquantizedWeight = 37;
        else if (quantizedWeight == 5) unquantizedWeight = 46;
        else if (quantizedWeight == 6) unquantizedWeight = 55;
    }
    else if (blockMode != ASTC_MODE_3X2_QUANT16)
    {
        if (quantizedWeight <= 0) unquantizedWeight = 0;
        else if (quantizedWeight == 1) unquantizedWeight = 21;
        else if (quantizedWeight == 2) unquantizedWeight = 43;
    }
    else
    {
        if (quantizedWeight <= 0) unquantizedWeight = 0;
        else if (quantizedWeight == 1) unquantizedWeight = 4;
        else if (quantizedWeight == 2) unquantizedWeight = 8;
        else if (quantizedWeight == 3) unquantizedWeight = 12;
        else if (quantizedWeight == 4) unquantizedWeight = 17;
        else if (quantizedWeight == 5) unquantizedWeight = 21;
        else if (quantizedWeight == 6) unquantizedWeight = 25;
        else if (quantizedWeight == 7) unquantizedWeight = 29;
        else if (quantizedWeight == 8) unquantizedWeight = 35;
        else if (quantizedWeight == 9) unquantizedWeight = 39;
        else if (quantizedWeight == 10) unquantizedWeight = 43;
        else if (quantizedWeight == 11) unquantizedWeight = 47;
        else if (quantizedWeight == 12) unquantizedWeight = 52;
        else if (quantizedWeight == 13) unquantizedWeight = 56;
        else if (quantizedWeight == 14) unquantizedWeight = 60;
    }

    return unquantizedWeight;
}
float ProjectWeight(float4 color, float4 endpoint0, float4 endpoint1)
{
    // RGBA全体をendpoint線分へ射影し、single-plane用の連続weight 0..1を求める
    float4 direction = endpoint1 - endpoint0;
    float lengthSquared = dot(direction, direction);
    if (lengthSquared <= 0.000001)
    {
        return 0.0;
    }

    return saturate(dot(color - endpoint0, direction) / lengthSquared);
}

float ProjectRgbWeight(float4 color, float4 endpoint0, float4 endpoint1)
{
    // dual-planeの第1plane用。alphaを除外してRGBだけをendpoint線分へ射影する
    float3 direction = endpoint1.rgb - endpoint0.rgb;
    float lengthSquared = dot(direction, direction);
    if (lengthSquared <= 0.000001)
    {
        return 0.0;
    }

    return saturate(dot(color.rgb - endpoint0.rgb, direction) / lengthSquared);
}

float ProjectAlphaWeight(float4 color, float4 endpoint0, float4 endpoint1)
{
    // dual-planeの第2plane用。RGBとは独立してalphaの補間位置を求める
    float direction = endpoint1.a - endpoint0.a;
    if (abs(direction) <= 0.000001)
    {
        return 0.0;
    }

    return saturate((color.a - endpoint0.a) / direction);
}

int WeightLocalX(int blockMode, int gridX)
{
    // 3x2 gridの3列を4texel上の0,2,3へ置き、規格補間時の代表sample位置を決める
    if (blockMode == ASTC_MODE_4X4_QUANT4) return gridX;
    return gridX == 0 ? 0 : (gridX == 1 ? 2 : 3);
}

int WeightLocalY(int blockMode, int gridY)
{
    // 3x2 gridの2行を4texel上の上端0と下端3へ対応させる
    if (blockMode == ASTC_MODE_4X4_QUANT4) return gridY;
    return gridY == 0 ? 0 : 3;
}

int WeightGridXFromIndex(int blockMode, int weightIndex)
{
    // 連番のweight indexを2次元grid座標へ戻す。4x4は下位2bitがX、3x2は明示mapping
    if (blockMode == ASTC_MODE_4X4_QUANT4) return weightIndex & 3;
    if (weightIndex == 0) return 0;
    if (weightIndex == 1) return 1;
    if (weightIndex == 2) return 2;
    if (weightIndex == 3) return 0;
    if (weightIndex == 4) return 1;
    return 2;
}

int WeightGridYFromIndex(int blockMode, int weightIndex)
{
    // 連番weight indexをgridのY座標へ戻す
    if (blockMode == ASTC_MODE_4X4_QUANT4) return weightIndex >> 2;
    return weightIndex < 3 ? 0 : 1;
}

int QuantizedWeightForPlane(int blockMode, int blockX, int blockY, float4 endpoint0, float4 endpoint1, int weightIndex, int plane)
{
    // grid代表位置のsource色をendpointへ射影し、mode固有の段階数へ丸める
    // dual-plane時だけplane 0=RGB、plane 1=alphaへ射影式を分ける
    int gridX = WeightGridXFromIndex(blockMode, weightIndex);
    int gridY = WeightGridYFromIndex(blockMode, weightIndex);
    int localX = WeightLocalX(blockMode, gridX);
    int localY = WeightLocalY(blockMode, gridY);

    float4 color = SourceColorAtLocal(blockX, blockY, localX, localY);
    float projectedWeight = ProjectWeight(color, endpoint0, endpoint1);
    if (blockMode == ASTC_MODE_3X2_DUAL_QUANT8)
    {
        projectedWeight = plane == 0 ? ProjectRgbWeight(color, endpoint0, endpoint1) : ProjectAlphaWeight(color, endpoint0, endpoint1);
    }

    return (int)round(projectedWeight * WeightQuantMax(blockMode));
}

int QuantizedWeight(int blockMode, int blockX, int blockY, float4 endpoint0, float4 endpoint1, int weightIndex)
{
    // single-plane処理用の短縮入口。常にplane 0を使う
    return QuantizedWeightForPlane(blockMode, blockX, blockY, endpoint0, endpoint1, weightIndex, 0);
}

int InterpolatedWeightForPlane(int blockMode, int blockX, int blockY, float4 endpoint0, float4 endpoint1, int localX, int localY, int plane)
{
    // ASTC decoderと同じ整数演算でgrid weightを4x4 texelへbilinear補間する
    // 342、4bit小数、0..64へのunquantizationは規格由来で、通常のfloat bilinearへ置換すると評価と実decodeがずれる
    int gridWidth = WeightGridWidth(blockMode);
    int gridHeight = WeightGridHeight(blockMode);
    int xWeight = (342 * localX * (gridWidth - 1) + 32) >> 6;
    int yWeight = (342 * localY * (gridHeight - 1) + 32) >> 6;

    int xFrac = xWeight & 15;
    int yFrac = yWeight & 15;
    int xInt = xWeight >> 4;
    int yInt = yWeight >> 4;

    int q0 = xInt + yInt * gridWidth;
    int q1 = q0 + 1;
    int q2 = q0 + gridWidth;
    int q3 = q2 + 1;
    int maxWeightIndex = gridWidth * gridHeight - 1;
    q0 = clamp(q0, 0, maxWeightIndex);
    q1 = clamp(q1, 0, maxWeightIndex);
    q2 = clamp(q2, 0, maxWeightIndex);
    q3 = clamp(q3, 0, maxWeightIndex);

    int product = xFrac * yFrac;
    int w3 = (product + 8) >> 4;
    int w1 = xFrac - w3;
    int w2 = yFrac - w3;
    int w0 = 16 - xFrac - yFrac + w3;

    int total = 0;
    if (w0 != 0) total += UnquantizedWeight(blockMode, QuantizedWeightForPlane(blockMode, blockX, blockY, endpoint0, endpoint1, q0, plane)) * w0;
    if (w1 != 0) total += UnquantizedWeight(blockMode, QuantizedWeightForPlane(blockMode, blockX, blockY, endpoint0, endpoint1, q1, plane)) * w1;
    if (w2 != 0) total += UnquantizedWeight(blockMode, QuantizedWeightForPlane(blockMode, blockX, blockY, endpoint0, endpoint1, q2, plane)) * w2;
    if (w3 != 0) total += UnquantizedWeight(blockMode, QuantizedWeightForPlane(blockMode, blockX, blockY, endpoint0, endpoint1, q3, plane)) * w3;
    return (total + 8) >> 4;
}

int InterpolatedWeight(int blockMode, int blockX, int blockY, float4 endpoint0, float4 endpoint1, int localX, int localY)
{
    // single-plane処理用の短縮入口。RGBとalphaへ同じ補間weightを適用する
    return InterpolatedWeightForPlane(blockMode, blockX, blockY, endpoint0, endpoint1, localX, localY, 0);
}

float4 DecodeColor(float4 endpoint0, float4 endpoint1, int unquantizedWeight)
{
    // 誤差評価用にdecoderと同じ0..64 weightで2 endpoint間を補間する
    return lerp(endpoint0, endpoint1, unquantizedWeight / 64.0);
}

float BlockError(int blockMode, int blockX, int blockY, float4 endpoint0, float4 endpoint1)
{
    // 量子化後endpointと補間weightで16texelを仮復元し、RGBA二乗誤差を合計する
    // 最大RGB誤差も加点し、平均誤差だけでは選ばれやすい孤立noise候補を避ける
    float4 encodedEndpoint0 = EncodedEndpointColor(endpoint0);
    float4 encodedEndpoint1 = EncodedEndpointColor(endpoint1);
    OrderDirectEndpoints(encodedEndpoint0, encodedEndpoint1);
    float error = 0.0;
    float worstRgbError = 0.0;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 source = SourceColorAtLocal(blockX, blockY, x, y);
            float4 decoded = DecodeColor(encodedEndpoint0, encodedEndpoint1, InterpolatedWeight(blockMode, blockX, blockY, encodedEndpoint0, encodedEndpoint1, x, y));
            float4 delta = source - decoded;
            error += dot(delta, delta);
            float3 absDelta = abs(delta.rgb);
            worstRgbError = max(worstRgbError, max(absDelta.r, max(absDelta.g, absDelta.b)));
        }
    }

    return error + worstRgbError * worstRgbError * 4.0;
}

float BlockDualAlphaError(int blockX, int blockY, float4 endpoint0, float4 endpoint1)
{
    // dual-plane候補はRGBとalphaを別weightで復元して評価する。第2planeはalpha固定
    float4 encodedEndpoint0 = EncodedEndpointColor(endpoint0);
    float4 encodedEndpoint1 = EncodedEndpointColor(endpoint1);
    OrderDirectEndpoints(encodedEndpoint0, encodedEndpoint1);
    float error = 0.0;
    float worstRgbError = 0.0;
    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 source = SourceColorAtLocal(blockX, blockY, x, y);
            int rgbWeight = InterpolatedWeightForPlane(ASTC_MODE_3X2_DUAL_QUANT8, blockX, blockY, encodedEndpoint0, encodedEndpoint1, x, y, 0);
            int alphaWeight = InterpolatedWeightForPlane(ASTC_MODE_3X2_DUAL_QUANT8, blockX, blockY, encodedEndpoint0, encodedEndpoint1, x, y, 1);
            float4 decoded = DecodeColor(encodedEndpoint0, encodedEndpoint1, rgbWeight);
            decoded.a = lerp(encodedEndpoint0.a, encodedEndpoint1.a, alphaWeight / 64.0);
            float4 delta = source - decoded;
            error += dot(delta, delta);
            float3 absDelta = abs(delta.rgb);
            worstRgbError = max(worstRgbError, max(absDelta.r, max(absDelta.g, absDelta.b)));
        }
    }

    return error + worstRgbError * worstRgbError * 4.0;
}

float RgbEndpointRange(float4 endpoint0, float4 endpoint1)
{
    // endpoint候補の最大RGB幅。過度なrefineでhigh contrast端が失われないための判定に使う
    float3 range = abs(endpoint1.rgb - endpoint0.rgb);
    return max(range.r, max(range.g, range.b));
}

float BlockRgbRange(int blockX, int blockY)
{
    // block自体の最大RGB幅。滑らかなblockでは4x4 mode採用条件をより厳しくする
    float4 minColor;
    float4 maxColor;
    GetColorBounds(blockX, blockY, minColor, maxColor);
    float3 range = maxColor.rgb - minColor.rgb;
    return max(range.r, max(range.g, range.b));
}

float BlockAlphaRange(int blockX, int blockY)
{
    // alphaが完全一定のblockではdual-planeを評価せず、余分な計算とweight bit消費を避ける
    float4 minColor;
    float4 maxColor;
    GetColorBounds(blockX, blockY, minColor, maxColor);
    return maxColor.a - minColor.a;
}

void FitEndpointsForCurrentWeights(int blockMode, int blockX, int blockY, float4 sourceEndpoint0, float4 sourceEndpoint1, out float4 fitEndpoint0, out float4 fitEndpoint1)
{
    // 現在の量子化weightを固定し、16texelに対して最小二乗法で2 endpointを再推定する
    // 2x2正規方程式をchannel並列で解き、行列が特異な場合は元endpointを保持する
    float4 encoded0 = EncodedEndpointColor(sourceEndpoint0);
    float4 encoded1 = EncodedEndpointColor(sourceEndpoint1);
    OrderDirectEndpoints(encoded0, encoded1);
    float s00 = 0.0;
    float s01 = 0.0;
    float s11 = 0.0;
    float4 c0 = 0.0;
    float4 c1 = 0.0;

    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 source = SourceColorAtLocal(blockX, blockY, x, y);
            float t = InterpolatedWeight(blockMode, blockX, blockY, encoded0, encoded1, x, y) / 64.0;
            float a = 1.0 - t;
            float b = t;
            s00 += a * a;
            s01 += a * b;
            s11 += b * b;
            c0 += source * a;
            c1 += source * b;
        }
    }

    float determinant = s00 * s11 - s01 * s01;
    if (abs(determinant) <= 0.000001)
    {
        fitEndpoint0 = encoded0;
        fitEndpoint1 = encoded1;
        return;
    }

    fitEndpoint0 = saturate((c0 * s11 - c1 * s01) / determinant);
    fitEndpoint1 = saturate((c1 * s00 - c0 * s01) / determinant);
}

void FitDualAlphaEndpointsForCurrentWeights(int blockX, int blockY, float4 sourceEndpoint0, float4 sourceEndpoint1, out float4 fitEndpoint0, out float4 fitEndpoint1)
{
    // dual-planeではRGB用とalpha用の正規方程式を別々に解く
    // endpoint自体はRGBA 2組を共有し、weightだけを2 planeへ分離するASTC layoutに合わせる
    float4 encoded0 = EncodedEndpointColor(sourceEndpoint0);
    float4 encoded1 = EncodedEndpointColor(sourceEndpoint1);
    OrderDirectEndpoints(encoded0, encoded1);
    float rgbS00 = 0.0;
    float rgbS01 = 0.0;
    float rgbS11 = 0.0;
    float3 rgbC0 = 0.0;
    float3 rgbC1 = 0.0;
    float alphaS00 = 0.0;
    float alphaS01 = 0.0;
    float alphaS11 = 0.0;
    float alphaC0 = 0.0;
    float alphaC1 = 0.0;

    for (int y = 0; y < 4; y++)
    {
        for (int x = 0; x < 4; x++)
        {
            float4 source = SourceColorAtLocal(blockX, blockY, x, y);
            float rgbT = InterpolatedWeightForPlane(ASTC_MODE_3X2_DUAL_QUANT8, blockX, blockY, encoded0, encoded1, x, y, 0) / 64.0;
            float rgbA = 1.0 - rgbT;
            rgbS00 += rgbA * rgbA;
            rgbS01 += rgbA * rgbT;
            rgbS11 += rgbT * rgbT;
            rgbC0 += source.rgb * rgbA;
            rgbC1 += source.rgb * rgbT;

            float alphaT = InterpolatedWeightForPlane(ASTC_MODE_3X2_DUAL_QUANT8, blockX, blockY, encoded0, encoded1, x, y, 1) / 64.0;
            float alphaA = 1.0 - alphaT;
            alphaS00 += alphaA * alphaA;
            alphaS01 += alphaA * alphaT;
            alphaS11 += alphaT * alphaT;
            alphaC0 += source.a * alphaA;
            alphaC1 += source.a * alphaT;
        }
    }

    fitEndpoint0 = encoded0;
    fitEndpoint1 = encoded1;
    float rgbDeterminant = rgbS00 * rgbS11 - rgbS01 * rgbS01;
    if (abs(rgbDeterminant) > 0.000001)
    {
        fitEndpoint0.rgb = saturate((rgbC0 * rgbS11 - rgbC1 * rgbS01) / rgbDeterminant);
        fitEndpoint1.rgb = saturate((rgbC1 * rgbS00 - rgbC0 * rgbS01) / rgbDeterminant);
    }

    float alphaDeterminant = alphaS00 * alphaS11 - alphaS01 * alphaS01;
    if (abs(alphaDeterminant) > 0.000001)
    {
        fitEndpoint0.a = saturate((alphaC0 * alphaS11 - alphaC1 * alphaS01) / alphaDeterminant);
        fitEndpoint1.a = saturate((alphaC1 * alphaS00 - alphaC0 * alphaS01) / alphaDeterminant);
    }
}

void DualAlphaEndpointsForCandidate(int blockX, int blockY, float4 candidate0, float4 candidate1, out float4 endpoint0, out float4 endpoint1)
{
    // RGBは候補endpointをseedにし、alphaだけblock内min/maxから開始してdual-plane fitする
    // 最後に8bit endpointへ量子化し、blue-contraction回避の順序も再適用する
    float4 minColor;
    float4 maxColor;
    GetColorBounds(blockX, blockY, minColor, maxColor);
    float4 seed0 = EncodedEndpointColor(candidate0);
    float4 seed1 = EncodedEndpointColor(candidate1);
    seed0.a = minColor.a;
    seed1.a = maxColor.a;
    OrderDirectEndpoints(seed0, seed1);
    FitDualAlphaEndpointsForCurrentWeights(blockX, blockY, seed0, seed1, endpoint0, endpoint1);
    endpoint0 = EncodedEndpointColor(endpoint0);
    endpoint1 = EncodedEndpointColor(endpoint1);
    OrderDirectEndpoints(endpoint0, endpoint1);
}

int ReverseByte(int value)
{
    // ASTC weight bit列はblock末尾側からLSB順に配置されるため、1byte内のbit順を反転する
    int reversed = 0;
    for (int bit = 0; bit < 8; bit++)
    {
        reversed |= ((value >> bit) & 1) << (7 - bit);
    }

    return reversed;
}

int PackedWeightByte(int blockMode, int blockX, int blockY, float4 endpoint0, float4 endpoint1, int byteIndex)
{
    // single-plane weightをblock末尾から詰める
    // 4x4 QUANT_4は2bit×4個、3x2 QUANT_16は4bit×2個を1byteへ格納する
    int packed = 0;
    if (blockMode == ASTC_MODE_4X4_QUANT4)
    {
        int sourceByte4x4 = 15 - byteIndex;
        int baseWeight = sourceByte4x4 * 4;
        int weight0 = QuantizedWeight(blockMode, blockX, blockY, endpoint0, endpoint1, baseWeight);
        int weight1 = QuantizedWeight(blockMode, blockX, blockY, endpoint0, endpoint1, baseWeight + 1);
        int weight2 = QuantizedWeight(blockMode, blockX, blockY, endpoint0, endpoint1, baseWeight + 2);
        int weight3 = QuantizedWeight(blockMode, blockX, blockY, endpoint0, endpoint1, baseWeight + 3);
        packed = weight0 | (weight1 << 2) | (weight2 << 4) | (weight3 << 6);
    }
    else
    {
        int sourceByte = 15 - byteIndex;
        int weight0 = QuantizedWeight(blockMode, blockX, blockY, endpoint0, endpoint1, sourceByte * 2);
        int weight1 = QuantizedWeight(blockMode, blockX, blockY, endpoint0, endpoint1, sourceByte * 2 + 1);
        packed = weight0 | (weight1 << 4);
    }

    return ReverseByte(packed);
}

int DualSequenceWeight(int blockX, int blockY, float4 endpoint0, float4 endpoint1, int sequenceIndex)
{
    // dual-planeのweight sequenceはRGB0,Alpha0,RGB1,Alpha1...の交互順になる
    int weightIndex = sequenceIndex >> 1;
    int plane = sequenceIndex & 1;
    return QuantizedWeightForPlane(ASTC_MODE_3X2_DUAL_QUANT8, blockX, blockY, endpoint0, endpoint1, weightIndex, plane);
}

int PackedDualWeightByte(int blockX, int blockY, float4 endpoint0, float4 endpoint1, int byteIndex)
{
    // QUANT_8の3bit値12個を、ASTCのtritなし固定sequenceとしてbyte境界をまたいで詰める
    // 汎用BISE encoderではなく、この0x59F layout専用のpackingである
    int sourceByte = 15 - byteIndex;
    int packed = 0;
    if (sourceByte == 0)
    {
        packed = DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 0)
            | (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 1) << 3)
            | ((DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 2) & 3) << 6);
    }
    else if (sourceByte == 1)
    {
        packed = (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 2) >> 2)
            | (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 3) << 1)
            | (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 4) << 4)
            | ((DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 5) & 1) << 7);
    }
    else if (sourceByte == 2)
    {
        packed = (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 5) >> 1)
            | (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 6) << 2)
            | (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 7) << 5);
    }
    else if (sourceByte == 3)
    {
        packed = DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 8)
            | (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 9) << 3)
            | ((DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 10) & 3) << 6);
    }
    else
    {
        packed = (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 10) >> 2)
            | (DualSequenceWeight(blockX, blockY, endpoint0, endpoint1, 11) << 1);
    }

    return ReverseByte(packed);
}

int EndpointByte(float4 endpoint0, float4 endpoint1, int endpointValueIndex)
{
    // endpoint値はR0,R1,G0,G1,B0,B1,A0,A1の順で8bit化する
    int channel = endpointValueIndex >> 1;
    float value = (endpointValueIndex & 1) == 0 ? Component(endpoint0, channel) : Component(endpoint1, channel);
    return ColorByte(value);
}

int EndpointShiftedByte(float4 endpoint0, float4 endpoint1, int byteIndex)
{
    // block headerがendpoint bit列へ1bit食い込むため、隣接endpoint byteを1bitずらして結合する
    int previousEndpoint = byteIndex >= 3 ? EndpointByte(endpoint0, endpoint1, byteIndex - 3) : 0;
    int currentEndpoint = byteIndex <= 9 ? EndpointByte(endpoint0, endpoint1, byteIndex - 2) : 0;
    return ((previousEndpoint >> 7) & 1) | ((currentEndpoint & 127) << 1);
}

int Astc4x4Byte(int blockMode, int blockX, int blockY, float4 endpoint0, float4 endpoint1, int byteIndex)
{
    // 16byte ASTC blockの指定位置を1byteずつ生成する
    // byte 0..1=block header、2..10=endpoint、末尾側=mode別weightという固定layout
    float4 orderedEndpoint0 = EncodedEndpointColor(endpoint0);
    float4 orderedEndpoint1 = EncodedEndpointColor(endpoint1);
    OrderDirectEndpoints(orderedEndpoint0, orderedEndpoint1);

    int value = 0;
    if (byteIndex == 0)
    {
        value = blockMode & 255;
    }
    else if (byteIndex == 1)
    {
        value = ((blockMode >> 8) & 7) | 0x80;
    }
    else if (byteIndex >= 2 && byteIndex <= 10)
    {
        value = EndpointShiftedByte(orderedEndpoint0, orderedEndpoint1, byteIndex);
        if (byteIndex == 2)
        {
            value |= 1;
        }
    }
    else if (blockMode == ASTC_MODE_3X2_DUAL_QUANT8 && byteIndex >= 11)
    {
        value = PackedDualWeightByte(blockX, blockY, orderedEndpoint0, orderedEndpoint1, byteIndex);
        if (byteIndex == 11)
        {
            // 2bitのdual-plane component selectorはweight列直下へ配置され、値3がalpha channelを指定する
            value |= 3 << 2;
        }
    }
    else if (blockMode == ASTC_MODE_4X4_QUANT4 && byteIndex >= 12)
    {
        value = PackedWeightByte(blockMode, blockX, blockY, orderedEndpoint0, orderedEndpoint1, byteIndex);
    }
    else if (blockMode == ASTC_MODE_3X2_QUANT16 && byteIndex >= 13)
    {
        value = PackedWeightByte(blockMode, blockX, blockY, orderedEndpoint0, orderedEndpoint1, byteIndex);
    }

    return value;
}

float4 fragFitEndpoints(Varyings i) : SV_Target
{
    // 候補Texture全体の幅
    int2 outputPixel = OutputPixel(i.uv, _CandidateOutputWidth, _OutputHeight);
    int blockX = (int)((uint)outputPixel.x / (uint)ASTC_CANDIDATE_ENDPOINT_PIXELS);
    int local = outputPixel.x - blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS;
    int candidateIndex = local >> 1;
    int endpointIndex = local & 1;
    float4 endpoint0 = ReadCandidateEndpoint(blockX, candidateIndex, 0, outputPixel.y);
    float4 endpoint1 = ReadCandidateEndpoint(blockX, candidateIndex, 1, outputPixel.y);
    float4 fitted0;
    float4 fitted1;
    // エンドポイントを再適合させるASTC block mode
    int blockMode = _FitBlockMode > 0.5 ? ASTC_MODE_4X4_QUANT4 : ASTC_MODE_3X2_QUANT16;
    FitEndpointsForCurrentWeights(blockMode, blockX, outputPixel.y, endpoint0, endpoint1, fitted0, fitted1);
    return endpointIndex == 0 ? fitted0 : fitted1;
}

void ReadSelectedCandidate(int blockX, int blockY, int candidateIndex, out float4 endpoint0, out float4 endpoint1, out int blockMode)
{
    endpoint0 = ReadCandidateEndpoint(blockX, candidateIndex, 0, blockY);
    endpoint1 = tex2Dlod(_CandidateTex, float4((float2(blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS + candidateIndex * 2 + 1, blockY) + 0.5) / float2(_CandidateOutputWidth, _OutputHeight), 0.0, 0.0));
    int modeCode = (int)floor(endpoint1.a * 0.5);
    endpoint1.a -= modeCode * 2.0;
    blockMode = modeCode == 1 ? ASTC_MODE_4X4_QUANT4 : (modeCode == 2 ? ASTC_MODE_3X2_DUAL_QUANT8 : ASTC_MODE_3X2_QUANT16);
}

float SelectedCandidateError(int blockMode, int blockX, int blockY, float4 endpoint0, float4 endpoint1)
{
    return blockMode == ASTC_MODE_3X2_DUAL_QUANT8
        ? BlockDualAlphaError(blockX, blockY, endpoint0, endpoint1)
        : BlockError(blockMode, blockX, blockY, endpoint0, endpoint1);
}

float4 EncodeSelectedCandidatePixel(int endpointIndex, float4 endpoint0, float4 endpoint1, int blockMode)
{
    if (endpointIndex == 0)
    {
        return endpoint0;
    }

    int modeCode = blockMode == ASTC_MODE_4X4_QUANT4 ? 1 : (blockMode == ASTC_MODE_3X2_DUAL_QUANT8 ? 2 : 0);
    endpoint1.a += modeCode * 2.0;
    return endpoint1;
}

float4 fragSelectStableMode(Varyings i) : SV_Target
{
    // 候補Texture全体の幅
    int2 outputPixel = OutputPixel(i.uv, _CandidateOutputWidth, _OutputHeight);
    int blockX = (int)((uint)outputPixel.x / (uint)ASTC_CANDIDATE_ENDPOINT_PIXELS);
    int local = outputPixel.x - blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS;
    int candidateIndex = local >> 1;
    int endpointIndex = local & 1;
    float4 stable0 = EncodedEndpointColor(ReadStableCandidateEndpoint(blockX, candidateIndex, 0, outputPixel.y));
    float4 stable1 = EncodedEndpointColor(ReadStableCandidateEndpoint(blockX, candidateIndex, 1, outputPixel.y));
    float error3x2 = BlockError(ASTC_MODE_3X2_QUANT16, blockX, outputPixel.y, stable0, stable1);
    float stable4x4Error = BlockError(ASTC_MODE_4X4_QUANT4, blockX, outputPixel.y, stable0, stable1);
    bool smoothBlock = BlockRgbRange(blockX, outputPixel.y) < 0.09;
    int selectedMode = stable4x4Error < error3x2 * (smoothBlock ? 0.55 : 0.85)
        ? ASTC_MODE_4X4_QUANT4
        : ASTC_MODE_3X2_QUANT16;
    return EncodeSelectedCandidatePixel(endpointIndex, stable0, stable1, selectedMode);
}

float4 fragSelectRefined4x4(Varyings i) : SV_Target
{
    // 候補Texture全体の幅
    int2 outputPixel = OutputPixel(i.uv, _CandidateOutputWidth, _OutputHeight);
    int blockX = (int)((uint)outputPixel.x / (uint)ASTC_CANDIDATE_ENDPOINT_PIXELS);
    int local = outputPixel.x - blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS;
    int candidateIndex = local >> 1;
    int endpointIndex = local & 1;
    float4 selected0;
    float4 selected1;
    int selectedMode;
    ReadSelectedCandidate(blockX, outputPixel.y, candidateIndex, selected0, selected1, selectedMode);
    float bestError = SelectedCandidateError(selectedMode, blockX, outputPixel.y, selected0, selected1);
    float error3x2 = BlockError(ASTC_MODE_3X2_QUANT16, blockX, outputPixel.y, selected0, selected1);
    float4 refined0 = EncodedEndpointColor(ReadAlternateCandidateEndpoint(blockX, candidateIndex, 0, outputPixel.y));
    float4 refined1 = EncodedEndpointColor(ReadAlternateCandidateEndpoint(blockX, candidateIndex, 1, outputPixel.y));
    float refinedError = BlockError(ASTC_MODE_4X4_QUANT4, blockX, outputPixel.y, refined0, refined1);
    float4 original0 = ReadOriginalCandidateEndpoint(blockX, candidateIndex, 0, outputPixel.y);
    float4 original1 = ReadOriginalCandidateEndpoint(blockX, candidateIndex, 1, outputPixel.y);
    float candidateRgbRange = RgbEndpointRange(original0, original1);
    bool smoothBlock = BlockRgbRange(blockX, outputPixel.y) < 0.09;
    float refinedThreshold = smoothBlock ? 0.45 : 0.75;
    float baselineThreshold = smoothBlock ? 0.40 : 0.65;
    if (candidateRgbRange < 0.85 && refinedError < bestError * refinedThreshold && refinedError < error3x2 * baselineThreshold)
    {
        selected0 = refined0;
        selected1 = refined1;
        selectedMode = ASTC_MODE_4X4_QUANT4;
    }
    return EncodeSelectedCandidatePixel(endpointIndex, selected0, selected1, selectedMode);
}

float4 fragSelectPreserved(Varyings i) : SV_Target
{
    // 候補Texture全体の幅
    int2 outputPixel = OutputPixel(i.uv, _CandidateOutputWidth, _OutputHeight);
    int blockX = (int)((uint)outputPixel.x / (uint)ASTC_CANDIDATE_ENDPOINT_PIXELS);
    int local = outputPixel.x - blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS;
    int candidateIndex = local >> 1;
    int endpointIndex = local & 1;
    float4 selected0;
    float4 selected1;
    int selectedMode;
    ReadSelectedCandidate(blockX, outputPixel.y, candidateIndex, selected0, selected1, selectedMode);
    float bestError = SelectedCandidateError(selectedMode, blockX, outputPixel.y, selected0, selected1);
    float4 preserved0 = EncodedEndpointColor(ReadOriginalCandidateEndpoint(blockX, candidateIndex, 0, outputPixel.y));
    float4 preserved1 = EncodedEndpointColor(ReadOriginalCandidateEndpoint(blockX, candidateIndex, 1, outputPixel.y));
    float candidateRgbRange = RgbEndpointRange(preserved0, preserved1);
    float preserved3x2Error = BlockError(ASTC_MODE_3X2_QUANT16, blockX, outputPixel.y, preserved0, preserved1);
    if (candidateRgbRange > 0.16 && preserved3x2Error < bestError * 0.92)
    {
        selected0 = preserved0;
        selected1 = preserved1;
        selectedMode = ASTC_MODE_3X2_QUANT16;
        bestError = preserved3x2Error;
    }
    float preserved4x4Error = BlockError(ASTC_MODE_4X4_QUANT4, blockX, outputPixel.y, preserved0, preserved1);
    if (candidateRgbRange > 0.16 && preserved4x4Error < bestError * 0.92)
    {
        selected0 = preserved0;
        selected1 = preserved1;
        selectedMode = ASTC_MODE_4X4_QUANT4;
    }
    return EncodeSelectedCandidatePixel(endpointIndex, selected0, selected1, selectedMode);
}

float4 fragSelectDualPlane(Varyings i) : SV_Target
{
    // 候補Texture全体の幅
    int2 outputPixel = OutputPixel(i.uv, _CandidateOutputWidth, _OutputHeight);
    int blockX = (int)((uint)outputPixel.x / (uint)ASTC_CANDIDATE_ENDPOINT_PIXELS);
    int local = outputPixel.x - blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS;
    int candidateIndex = local >> 1;
    int endpointIndex = local & 1;
    float4 selected0;
    float4 selected1;
    int selectedMode;
    ReadSelectedCandidate(blockX, outputPixel.y, candidateIndex, selected0, selected1, selectedMode);
    float bestError = SelectedCandidateError(selectedMode, blockX, outputPixel.y, selected0, selected1);
    if (_EnableDualPlane > 0.5 && BlockAlphaRange(blockX, outputPixel.y) > 0.00392156862)
    {
        float4 original0 = ReadOriginalCandidateEndpoint(blockX, candidateIndex, 0, outputPixel.y);
        float4 original1 = ReadOriginalCandidateEndpoint(blockX, candidateIndex, 1, outputPixel.y);
        float4 dual0;
        float4 dual1;
        DualAlphaEndpointsForCandidate(blockX, outputPixel.y, original0, original1, dual0, dual1);
        float dualError = BlockDualAlphaError(blockX, outputPixel.y, dual0, dual1);
        if (dualError < bestError)
        {
            selected0 = dual0;
            selected1 = dual1;
            selectedMode = ASTC_MODE_3X2_DUAL_QUANT8;
        }
    }
    return EncodeSelectedCandidatePixel(endpointIndex, selected0, selected1, selectedMode);
}

float4 CandidateEndpointsPairFrag(Varyings i, int sourceBatch, int sourceCandidateOffset)
{
    // 候補Texture全体の幅
    int2 outputPixel = OutputPixel(i.uv, _CandidateOutputWidth, _OutputHeight);
    int blockX = (int)((uint)outputPixel.x / (uint)ASTC_CANDIDATE_ENDPOINT_PIXELS);
    int local = outputPixel.x - blockX * ASTC_CANDIDATE_ENDPOINT_PIXELS;
    int sourceCandidateIndex = (local >> 1) + sourceCandidateOffset;
    float4 endpoint0 = 0.0;
    float4 endpoint1 = 0.0;
    if (sourceBatch == 0) GetCandidateEndpointsBatch0(blockX, outputPixel.y, sourceCandidateIndex, endpoint0, endpoint1);
    else if (sourceBatch == 1) GetCandidateEndpointsBatch1(blockX, outputPixel.y, sourceCandidateIndex, endpoint0, endpoint1);
    else GetCandidateEndpointsBatch2(blockX, outputPixel.y, sourceCandidateIndex, endpoint0, endpoint1);
    return (local & 1) == 0 ? endpoint0 : endpoint1;
}

float4 fragCandidateEndpointsBatch0(Varyings i) : SV_Target
{
    return CandidateEndpointsPairFrag(i, 0, 0);
}

float4 fragCandidateEndpointsBatch1(Varyings i) : SV_Target
{
    return CandidateEndpointsPairFrag(i, 0, 2);
}

float4 fragCandidateEndpointsBatch2(Varyings i) : SV_Target
{
    return CandidateEndpointsPairFrag(i, 1, 0);
}

float4 fragCandidateEndpointsBatch3(Varyings i) : SV_Target
{
    return CandidateEndpointsPairFrag(i, 1, 2);
}

float4 fragCandidateEndpointsBatch4(Varyings i) : SV_Target
{
    return CandidateEndpointsPairFrag(i, 2, 0);
}

float4 fragCandidateEndpointsBatch5(Varyings i) : SV_Target
{
    return CandidateEndpointsPairFrag(i, 2, 2);
}

float4 fragBestCandidate(Varyings i) : SV_Target
{
    // 最良候補Textureの幅
    int2 outputPixel = OutputPixel(i.uv, _BestOutputWidth, _OutputHeight);
    int blockX = (int)((uint)outputPixel.x / (uint)ASTC_BEST_PIXELS);
    int local = outputPixel.x - blockX * ASTC_BEST_PIXELS;

    int bestCandidate = 0;
    int bestMode = ASTC_MODE_3X2_QUANT16;
    float bestError = 1000000.0;
    for (int candidateIndex = 0; candidateIndex < ASTC_CANDIDATE_BATCH_SIZE; candidateIndex++)
    {
        float4 candidate0;
        float4 candidate1;
        int candidateMode;
        ReadSelectedCandidate(blockX, outputPixel.y, candidateIndex, candidate0, candidate1, candidateMode);
        float candidateError = SelectedCandidateError(candidateMode, blockX, outputPixel.y, candidate0, candidate1);
        if (candidateError < bestError)
        {
            bestError = candidateError;
            bestCandidate = candidateIndex;
            bestMode = candidateMode;
        }
    }

    float4 endpoint0 = 0.0;
    float4 endpoint1 = 0.0;
    int selectedMode;
    ReadSelectedCandidate(blockX, outputPixel.y, bestCandidate, endpoint0, endpoint1, selectedMode);
    if (_HasPreviousBest > 0.5)
    {
        float4 previousMetadata = ReadPreviousBestPixel(blockX, 2, outputPixel.y);
        if (previousMetadata.a <= bestError)
        {
            return ReadPreviousBestPixel(blockX, local, outputPixel.y);
        }
    }
    if (local == 0)
    {
        return endpoint0;
    }
    if (local == 1)
    {
        return endpoint1;
    }

    // mode情報も作業TextureのRGBAへflag化して保存し、最終packing passで整数modeへ戻す
    float modeFlag = bestMode == ASTC_MODE_4X4_QUANT4 ? 1.0 : 0.0;
    float dualPlaneFlag = bestMode == ASTC_MODE_3X2_DUAL_QUANT8 ? 1.0 : 0.0;
    return float4(modeFlag, (_CandidateBatchOffset + bestCandidate) / 255.0, dualPlaneFlag, bestError);
}

float4 fragPackBytes(Varyings i) : SV_Target
{
    // Pass 9: 横4pixelを1 ASTC blockへ対応させ、各RGBAへ連続4byteを書き出す
    // 出力RenderTextureはRGBA32なので、0..255を0..1へ正規化して格納しreadback時に元のbyteへ戻る
    int2 outputPixel = OutputPixel(i.uv, _OutputWidth, _OutputHeight);
    int blockX = outputPixel.x >> 2;
    int blockY = outputPixel.y;
    int byteBase = (outputPixel.x & 3) * 4;

    float4 endpoint0 = ReadBestPixel(blockX, 0, blockY);
    float4 endpoint1 = ReadBestPixel(blockX, 1, blockY);
    float4 modePixel = ReadBestPixel(blockX, 2, blockY);
    int blockMode = modePixel.b > 0.5 ? ASTC_MODE_3X2_DUAL_QUANT8 : (modePixel.r > 0.5 ? ASTC_MODE_4X4_QUANT4 : ASTC_MODE_3X2_QUANT16);

    return float4(
        Astc4x4Byte(blockMode, blockX, blockY, endpoint0, endpoint1, byteBase) * 0.00392156862,
        Astc4x4Byte(blockMode, blockX, blockY, endpoint0, endpoint1, byteBase + 1) * 0.00392156862,
        Astc4x4Byte(blockMode, blockX, blockY, endpoint0, endpoint1, byteBase + 2) * 0.00392156862,
        Astc4x4Byte(blockMode, blockX, blockY, endpoint0, endpoint1, byteBase + 3) * 0.00392156862);
}
