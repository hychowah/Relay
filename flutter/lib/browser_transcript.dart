import 'dart:convert';

import 'relay_api.dart';

// Desktop Browser only: the agent's browser.transcript operation and the chat
// panel's transcript pane. YouTube is the only supported site; this file holds
// all of its site-specific code.
//
// The page's own transcript panel request (get_panel) is replayed with the
// user's session. Caption file URLs need a player-made proof-of-origin token,
// and get_transcript is refused. The script reads the current video from the
// player because ytInitial* data stays on the first video after in-page
// navigation. The request's hl selects the spoken language, whose manual
// track YouTube prefers over its automatic one. The result is posted back
// through RelayBrowser because WebKit does not return a script's promise.
const youtubeTranscriptScript = r'''void (async()=>{
 const send=(reply)=>RelayBrowser.postMessage('transcript:'+JSON.stringify({id:REQUEST_ID,...reply}));
 try{
  if(!/(^|\.)youtube\.com$/.test(location.hostname)||location.pathname!=='/watch')
   throw Error('Open a YouTube video page (youtube.com/watch) in this tab to read its transcript.');
  const id=new URLSearchParams(location.search).get('v');
  const video=document.getElementById('movie_player')?.getPlayerResponse?.();
  if(!/^[\w-]{11}$/.test(id||'')||video?.videoDetails?.videoId!==id)
   throw Error('The video is still loading. Try again in a moment.');
  const captions=video.captions?.playerCaptionsTracklistRenderer;
  const tracks=captions?.captionTracks||[];
  if(!tracks.length)throw Error('This video has no captions, so it has no transcript.');
  const spoken=tracks.find((t)=>t.kind==='asr')
   ||tracks[captions.audioTracks?.[captions.defaultAudioTrackIndex||0]?.defaultCaptionTrackIndex]||tracks[0];
  const track=tracks.find((t)=>t.languageCode===spoken.languageCode&&t.kind!=='asr')||spoken;
  const context=ytcfg.get('INNERTUBE_CONTEXT');
  const response=await fetch('/youtubei/v1/get_panel?prettyPrint=false',{method:'POST',
   headers:{'Content-Type':'application/json'},
   body:JSON.stringify({context:{...context,client:{...context.client,hl:track.languageCode}},
    panelId:'PAmodern_transcript_view',params:btoa('\xaa\x09\x0f\x0a\x0b'+id+'\x18\x02')})});
  if(!response.ok)throw Error('YouTube did not return the transcript (HTTP '+response.status+').');
  const segments=[];
  (function walk(node){
   if(Array.isArray(node))node.forEach(walk);
   else if(node&&typeof node==='object'){
    const segment=node.transcriptSegmentViewModel;
    if(segment)segments.push({time:String(segment.timestamp||''),text:String(segment.simpleText||'')});
    else Object.values(node).forEach(walk);
   }
  })(await response.json());
  if(!segments.length)throw Error('YouTube returned no transcript for this video.');
  send({data:{url:location.href,title:video.videoDetails.title||document.title,
   language:track.name?.simpleText||track.languageCode,segments}});
 }catch(error){send({error:String(error?.message||error)})}
})()''';

/// Identifies a YouTube video page, where the chat panel offers its transcript.
String? youtubeVideoId(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !RegExp(r'(^|\.)youtube\.com$').hasMatch(uri.host) ||
      uri.path != '/watch') {
    return null;
  }
  return uri.queryParameters['v'];
}

/// Joins caption segments into paragraphs, each starting with its time.
Json transcriptFromSegments(Json data) {
  final paragraphs = <String>[];
  var paragraph = '';
  for (final segment in data['segments'] as List) {
    final text = '${segment['text']}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) continue;
    paragraph = paragraph.isEmpty
        ? '[${segment['time']}] $text'
        : '$paragraph $text';
    if (paragraph.length >= 600) {
      paragraphs.add(paragraph);
      paragraph = '';
    }
  }
  if (paragraph.isNotEmpty) paragraphs.add(paragraph);
  return {
    'url': data['url'],
    'title': data['title'],
    'language': data['language'],
    'text': paragraphs.join('\n'),
  };
}

// OpenCode truncates a tool result above 51,200 bytes, so a page stays well
// below it in UTF-8 even for non-Latin text.
const transcriptPageBytes = 30000;

/// Returns whole paragraphs from [offset] that fit in one page.
Json transcriptPage(Json transcript, int offset) {
  final text = transcript['text'] as String;
  if (offset < 0 || offset >= text.length) {
    throw RangeError(
      'The transcript has ${text.length} characters; '
      'offset $offset is outside it.',
    );
  }
  var end = offset, bytes = 0;
  while (end < text.length) {
    final next = text.indexOf('\n', end) + 1;
    final stop = next == 0 ? text.length : next;
    bytes += utf8.encode(text.substring(end, stop)).length;
    if (bytes > transcriptPageBytes && end > offset) break;
    end = stop;
  }
  return {
    'url': transcript['url'],
    'title': transcript['title'],
    'language': transcript['language'],
    'offset': offset,
    'totalLength': text.length,
    'text': text.substring(offset, end),
    if (end < text.length) 'nextOffset': end,
  };
}
