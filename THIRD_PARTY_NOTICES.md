# Third-party notices

## CrispASR runtime
- Source: https://github.com/CrispStrobe/CrispASR
- License: MIT

## SenseVoice-Small (GGUF Q8_0)
- Source: https://huggingface.co/cstr/sensevoice-small-GGUF
  (GGUF quantization of https://huggingface.co/FunAudioLLM/SenseVoiceSmall
  — format conversion only, no modification of weights or architecture)
- License: Apache-2.0

## FunASR-Nano (GGUF Q8_0)
- Source: https://huggingface.co/cstr/funasr-nano-GGUF
  (GGUF quantization of the FunASR Nano model from the FunASR project,
  https://github.com/modelscope/FunASR — format conversion only, no
  modification of weights or architecture)
- License: Apache-2.0

## FireRedVAD (GGUF)
- Source: https://huggingface.co/FireRedTeam/FireRedVAD
  (GGUF conversion: https://huggingface.co/cstr/firered-vad-GGUF — format
  conversion only, no modification of weights or architecture)
- License: Apache-2.0

## Vibrato (Japanese morphological tokenizer)
- Source: https://github.com/daac-tools/vibrato
- License: Apache-2.0 OR MIT (dual-licensed; terms usable at our option,
  see https://github.com/daac-tools/vibrato/blob/v0.5.2/README.md)

## IPADIC (Japanese dictionary data, compiled model)
- Source: mecab-ipadic 2.7.0-20070801 (© NAIST), compiled by LegalOn
  Technologies into the `ipadic-mecab-2_7_0` model (connection ids
  remapped using BCCWJ CORE data — see the NOTICE text below)
- License: custom permissive (NAIST / LegalOn Technologies / ICOT), the
  full required text reproduced verbatim below.

The dictionary model ships with the following `COPYING` text, reproduced
verbatim:

```
Copyright 2000, 2001, 2002, 2003 Nara Institute of Science
and Technology.
Copyright 2023, LegalOn Technologies, Inc.
All Rights Reserved.

Use, reproduction, and distribution of this software is permitted.
Any copy of this software, whether in its original form or modified,
must include both the above copyright notice and the following
paragraphs.

Nara Institute of Science and Technology (NAIST),
the copyright holders, disclaims all warranties with regard to this
software, including all implied warranties of merchantability and
fitness, in no event shall NAIST be liable for
any special, indirect or consequential damages or any damages
whatsoever resulting from loss of use, data or profits, whether in an
action of contract, negligence or other tortuous action, arising out
of or in connection with the use or performance of this software.

A large portion of the dictionary entries
originate from ICOT Free Software.  The following conditions for ICOT
Free Software applies to the current dictionary as well.

Each User may also freely distribute the Program, whether in its
original form or modified, to any third party or parties, PROVIDED
that the provisions of Section 3 ("NO WARRANTY") will ALWAYS appear
on, or be attached to, the Program, which is distributed substantially
in the same form as set out herein and that such intended
distribution, if actually made, will neither violate or otherwise
contravene any of the laws and regulations of the countries having
jurisdiction over the User or the intended distribution itself.

NO WARRANTY

The program was produced on an experimental basis in the course of the
research and development conducted during the project and is provided
to users as so produced on an experimental basis.  Accordingly, the
program is provided without any warranty whatsoever, whether express,
implied, statutory or otherwise.  The term "warranty" used herein
includes, but is not limited to, any warranty of the quality,
performance, merchantability and fitness for a particular purpose of
the program and the nonexistence of any infringement or violation of
any right of any third party.

Each user of the program will agree and understand, and be deemed to
have agreed and understood, that there is no warranty whatsoever for
the program and, accordingly, the entire risk arising from or
otherwise connected with the program is assumed by the user.

Therefore, neither ICOT, the copyright holder, or any other
organization that participated in or was otherwise related to the
development of the program and their respective officials, directors,
officers and other employees shall be held liable for any and all
damages, including, without limitation, general, special, incidental
and consequential damages, arising out of or otherwise in connection
with the use or inability to use the program or any product, material
or result produced or otherwise obtained by using the program,
regardless of whether they have been advised of, or otherwise had
knowledge of, the possibility of such damages at any time during the
project or thereafter.  Each user will be deemed to have agreed to the
foregoing by his or her commencement of use of the program.  The term
"use" as used herein includes, but is not limited to, the use,
modification, copying and distribution of the program and the
production of secondary products from the program.

In the case where the program, whether in its original form or
modified, was distributed or delivered to or received by a user from
any person, organization or entity other than ICOT, unless it makes or
grants independently of ICOT any specific warranty to the user in
writing, such person, organization or entity, will also be exempted
from and not be held liable to the user for any such damages as noted
above as far as the program is concerned.
```

And the model's `NOTICE` text, verbatim:

```
This software includes a binary version of data from

  http://jaist.dl.sourceforge.net/project/mecab/mecab-ipadic/2.7.0-20070801/mecab-ipadic-2.7.0-20070801.tar.gz,

where the connection ids are remapped using CORE data in BCCWJ (except the PN category)

  https://clrd.ninjal.ac.jp/bccwj/.
```

## JMdict (Japanese–English dictionary data)
- Source: JMdict/EDRDG, https://www.edrdg.org/jmdict/j_jmdict.html
  (obtained via the jmdict-simplified JSON conversion,
  https://github.com/scriptin/jmdict-simplified)
- License: Creative Commons Attribution-ShareAlike 4.0,
  https://creativecommons.org/licenses/by-sa/4.0/ (dictionary content,
  © Electronic Dictionary Research & Development Group); the jmdict-simplified
  conversion code itself is MIT.
- Required attribution: "JMdict data is provided by EDRDG under CC BY-SA 4.0."
  The ShareAlike obligation applies to the dictionary data files themselves,
  not to Mimidasu's source code.

## JMnedict (Japanese proper-noun dictionary data)
- Source: JMnedict/EDRDG, https://www.edrdg.org/jmdict/j_jmdict.html
  (obtained via the jmdict-simplified JSON conversion,
  https://github.com/scriptin/jmdict-simplified)
- License: Creative Commons Attribution-ShareAlike 4.0,
  https://creativecommons.org/licenses/by-sa/4.0/ (dictionary content,
  © Electronic Dictionary Research & Development Group); the jmdict-simplified
  conversion code itself is MIT.
- Required attribution: "JMnedict data is provided by EDRDG under CC BY-SA 4.0."
  The ShareAlike obligation applies to the dictionary data files themselves,
  not to Mimidasu's source code.

## JMDict_Extended (compiled JMdict + JLPT/pitch/furigana extensions)
- Source: https://github.com/Bluskyo/JMDict_Extended
- License: MIT (Bluskyo's compilation scripts, `LICENSE-DATA.md`); the
  compiled JSON inherits the licenses of its sources (JMdict/EDRDG above,
  JLPT vocabulary, Wadoku pitch, JmdictFurigana below).

## JLPT vocabulary annotations (via JMDict_Extended)
- Data: JLPT vocab lists by Jonathan Waller, https://www.tanos.co.uk/jlpt/
  (compiled by https://github.com/Bluskyo/JLPT_Vocabulary)
- License: CC BY 4.0, https://creativecommons.org/licenses/by/4.0/
  (data, © Jonathan Waller); MIT (Bluskyo scripts).

## Wadoku pitch-accent annotations (via JMDict_Extended)
- Data: Wadoku pitch dump, consumed through
  https://github.com/IllDepence/anki_add_pitch (`wadoku_parse.py`,
  `wadoku_pitchdb.json`)
- License: MIT.

## JmdictFurigana (via JMDict_Extended)
- Source: https://github.com/Doublevil/JmdictFurigana
- License: MIT.

## Apple frameworks
- Translation framework (macOS 15+), Core Audio process tap (macOS 15+):
  platform components, no redistribution required.
