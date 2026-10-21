import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.stdout.reconfigure(encoding="utf-8")

try:
    import pytest
except ImportError:
    pytest = None
from content_cleaner import clean_markdown_article

SAMPLE_WCCFTECH = """# NVIDIA’s CUDA Moat Is Accelerating RTX Spark Laptop Sales

[Omar Sohail](https://wccftech.com/author/omarsohail/) • [Comments](#comments)

Microsoft’s product page for the Surface Laptop Ultra shows the RTX Spark, 128GB unified memory configuration is out of stock.

## The full NVIDIA software stack is a prime factor

With unified memory architecture paired with NVIDIA’S RTX platform and CUDA support, developers will find machines like the Surface Laptop Ultra useful.

[##### **Related Story** ASUS Markets Its RTX Spark-Powered ProArt GR1X Mini-PCs As Efficient Gaming Powerhouses](https://wccftech.com/asus-story)

Sure, rival platforms like AMD Ryzen AI MAX offer large memory pools, but few can match that software compatibility.

**About the [author](https://wccftech.com/author/omarsohail/):** Omar Sohail is a reporter for Wccftech.

### Further Reading

### [Microsoft Is Doubling-Down On Its Copilot+ Brand](https://wccftech.com/story-1)

### Trending Stories

* #### [Starfield Players Wanted No Man's Sky Landings](https://wccftech.com/story-2)
* #### [Elon Musk Admits He Does Not Know How To Make Chips](https://wccftech.com/story-3)
"""

def test_clean_wccftech_sample():
    cleaned, truncated = clean_markdown_article(SAMPLE_WCCFTECH)
    assert truncated is True
    # Verify core content retained
    assert "CUDA Moat Is Accelerating RTX Spark Laptop Sales" in cleaned
    assert "The full NVIDIA software stack is a prime factor" in cleaned
    assert "AMD Ryzen AI MAX" in cleaned
    
    # Verify clutter stripped
    assert "About the author" not in cleaned
    assert "Further Reading" not in cleaned
    assert "Trending Stories" not in cleaned
    assert "Starfield Players Wanted" not in cleaned
    assert "Elon Musk Admits" not in cleaned
    assert "Related Story" not in cleaned
    assert "Omar Sohail •" not in cleaned

def test_preserve_technical_code_and_lists():
    technical_article = """# Understanding PyTorch CUDA Memory Allocation

Here is how you monitor memory in PyTorch:

```python
import torch
print(torch.cuda.memory_allocated())
```

Key hardware considerations:

* Ensure unified memory paging is enabled.
* Monitor peak allocation during inference.
* Always clear the cache between batch runs.

Conclusion:
Local execution remains highly efficient with proper allocation management.
"""
    cleaned, truncated = clean_markdown_article(technical_article)
    assert truncated is False
    assert "import torch" in cleaned
    assert "Ensure unified memory paging is enabled" in cleaned
    assert "Conclusion:" in cleaned

def test_safety_guardrail_short_article():
    short_article = "Brief breaking report: TSMC confirms expansion of 2nm facility ahead of schedule with 82% initial test yield across high-density GAAFET wafers."
    cleaned, truncated = clean_markdown_article(short_article)
    assert cleaned == short_article
    assert truncated is False

def test_strip_images_and_base64():
    sample = (
        "# Major Breakthrough in Quantum Photonics\n\n"
        "![Company Logo](https://example.com/logo.png)\n\n"
        "Researchers have developed a nanoscale photon emitter operating at room temperature with 99.8% single-photon purity.\n\n"
        "![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=)\n\n"
        "The device uses a photonic crystal cavity coupled to an atomic defect in hexagonal boron nitride."
    )
    cleaned, _ = clean_markdown_article(sample)
    assert "data:image" not in cleaned
    assert "Company Logo" not in cleaned
    assert "Major Breakthrough in Quantum Photonics" in cleaned
    assert "nanoscale photon emitter" in cleaned

def test_strip_cookie_and_paywall_banners():
    sample = (
        "We use cookies to improve your experience. [Read our cookie policy](https://example.com/cookies)\n\n"
        "### Go Unlimited with Magzter GOLD\n\n"
        "Get unlimited access to 10,000+ magazines for just $149.99/Year\n\n"
        "[Try GOLD - Free](https://example.com/pay)\n\n"
        "# Resident Evil Returns to Production\n\n"
        "Filming for the upcoming Resident Evil cinematic adaptation began today in Toronto under director Paul Anderson.\n\n"
        "The studio confirmed a theatrical release window slated for late summer next year."
    )
    cleaned, _ = clean_markdown_article(sample, title="Resident Evil Returns to Production")
    assert "cookie policy" not in cleaned.lower()
    assert "Magzter GOLD" not in cleaned
    assert "$149.99" not in cleaned
    assert "Resident Evil Returns to Production" in cleaned
    assert "Filming for the upcoming Resident Evil" in cleaned

def test_strip_app_download_and_ui_buttons():
    sample = (
        "# Clean Energy Investment Hits New Record in 2026\n\n"
        "Global venture funding into geothermal and advanced modular reactor startups reached $14.2 billion this quarter.\n\n"
        "Analysts attribute this surge to increased baseload electricity demand from hyperscale artificial intelligence data centers.\n\n"
        "## Download the CNN app\n\n"
        "Scan the QR code to download the CNN app on Google Play.\n\n"
        "![Scan the QR code](https://example.com/qr.png)\n\n"
        "Translate\n\n"
        "Share\n\n"
        "Change font size"
    )
    cleaned, truncated = clean_markdown_article(sample)
    assert "Download the CNN app" not in cleaned
    assert "Scan the QR code" not in cleaned
    assert "Translate" not in cleaned
    assert "Change font size" not in cleaned
    assert "Clean Energy Investment Hits New Record" in cleaned

if __name__ == "__main__":
    test_clean_wccftech_sample()
    print("✓ test_clean_wccftech_sample passed")
    test_preserve_technical_code_and_lists()
    print("✓ test_preserve_technical_code_and_lists passed")
    test_safety_guardrail_short_article()
    print("✓ test_safety_guardrail_short_article passed")
    test_strip_images_and_base64()
    print("✓ test_strip_images_and_base64 passed")
    test_strip_cookie_and_paywall_banners()
    print("✓ test_strip_cookie_and_paywall_banners passed")
    test_strip_app_download_and_ui_buttons()
    print("✓ test_strip_app_download_and_ui_buttons passed")
    print("\nAll content cleaner unit tests passed!")
