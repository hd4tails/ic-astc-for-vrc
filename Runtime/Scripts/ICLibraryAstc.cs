using UdonSharp;
using UnityEngine;
using VRC.SDKBase;

namespace HDAssets.ImageCompress.Astc
{
    /// <summary>
    /// ASTCの圧縮・展開ライブラリオブジェクトの参照を保持する
    /// ASTCを使用するUdonにはこのオブジェクトを指定する
    /// 圧縮と展開の処理は参照先の各ライブラリオブジェクトが実行する
    /// </summary>
    [UdonBehaviourSyncMode(BehaviourSyncMode.NoVariableSync)]
    public class ICLibraryAstc : UdonSharpBehaviour
    {
        [Header("Library Objects")]
        // Libraryの単位はASTCとし、現在のライブラリオブジェクト実装は子オブジェクト内でASTC 4x4を扱う
        // 圧縮・展開を別ライブラリオブジェクトにすることで、PCの並行処理時も作業RTを共有しない
        public AstcCompressionLibrary compression;
        // ASTC展開処理を実行するライブラリオブジェクト
        public AstcExpansionLibrary expansion;
    }
}
