# H68/TRのテープフォーマットWAVファイルを介してパソコンとファイル交換

H68/TRとパソコンが連携できるようH68/TRで出力されるテープフォーマットWAVファイルとパソコンのAssembler等で出力されるバイナリファイルを相互に変換できるツールを作成しました。

## 使い方
### BIN2WAV.exe
　パソコンのAssembler等で出力されるバイナリファイルをH68/TRで読み込めるWAVファイルに変換します。
 
　書式)

　　BIN2WAV input.bin output.wav 0100
 
　　input.binを$0100からLoadするファイルとしてoutput.wavファイルを作成します。

### WAV2BIN.exe
　H68/TRで出力されるWAVファイルをパソコンでプログラムと認識できるバイナリファイルに変換します。
 
　書式)

　　WAV2BIN input.wav output.bin

　　アドレス情報は失われます。
