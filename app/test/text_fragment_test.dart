import 'package:flutter_test/flutter_test.dart';

import 'package:weownfeed/models/api_models.dart';
import 'package:weownfeed/services/text_fragment.dart';

void main() {
  test('short quote is one text fragment', () {
    expect(
      quoteLink('https://cnbc.com/a#top', 'Nvidia shares rose 4%'),
      'https://cnbc.com/a#:~:text=Nvidia%20shares%20rose%204%25',
    );
  });

  test('long quote uses its first and last words', () {
    expect(
      quoteLink(
        'https://cnbc.com/a',
        'The company said on Tuesday that its new data-center chips will ship in March, ahead of plan.',
      ),
      'https://cnbc.com/a#:~:text=The%20company%20said%20on,March%2C%20ahead%20of%20plan',
    );
  });

  test('quote cut at 150 characters drops its broken last word', () {
    final quote = '${'word ' * 29}broke'; // 145 + 5 = 150 characters
    expect(quote.length, 150);
    expect(quoteLink('https://x.com', quote).endsWith('word%20word'), isTrue);
  });

  test('markdown marks and links are removed', () {
    expect(
      quoteLink(
        'https://x.com',
        '**Revenue** rose, said [CEO Jensen Huang](https://x.com/j)',
      ),
      'https://x.com#:~:text=Revenue%20rose%2C%20said%20CEO%20Jensen%20Huang',
    );
  });

  test('Markdown left over at the start is dropped', () {
    expect(
      quoteLink('https://x.com', '] The percentage of youths | turning to'),
      'https://x.com#:~:text=The%20percentage%20of%20youths%20turning%20to',
    );
  });

  test('older results take the quote from the evidence line', () {
    final claim = ClaimItem.fromJson({
      'claim': 'Shares rose',
      'status': 'supported',
      'evidence_summary':
          'Corroborated by cnbc.com: "Nvidia shares rose 4% on Tuesday" (2 independent origin(s))',
      'source_url': 'https://cnbc.com/a',
    });
    expect(claim.quote, 'Nvidia shares rose 4% on Tuesday');
  });
}
