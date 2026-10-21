import '../models/api_models.dart';

/// Made-up sample stories, NOT real news: placeholders for the planned
/// offline mode. The app never shows them as a feed.
const seedArticles = <Article>[
  Article(
    id: 'seed-1',
    source: 'TechCrunch',
    title: 'OpenAI Unveils GPT-5 With Breakthrough Reasoning Capabilities',
    url: 'https://example.com/gpt5',
    author: 'Sarah Chen',
    publishedAt: null,
    macroTag: 'AI',
    macroTags: ['AI', 'Tech'],
    microTags: ['OpenAI', 'GPT-5', 'LLM', 'Reasoning'],
    tldr:
        'OpenAI has released GPT-5, featuring significant improvements in multi-step reasoning, code generation, and factual accuracy. The model introduces a new "chain-of-verification" architecture that reduces hallucinations by 60% compared to its predecessor.',
    cleanText:
        'OpenAI has officially launched GPT-5, the latest iteration of its flagship large language model. The new model demonstrates a significant leap in reasoning capabilities, particularly in multi-step problem solving and mathematical proofs.\n\nThe company claims GPT-5 achieves a 60% reduction in hallucinations through a novel "chain-of-verification" architecture that cross-references its own outputs before presenting them to users. Early benchmarks show the model outperforming previous versions across all major evaluation suites.\n\nKey improvements include enhanced code generation with support for 40+ programming languages, better long-context understanding up to 256K tokens, and native multimodal capabilities that process images, audio, and video in a single pass.\n\nIndustry analysts note that this release intensifies the AI race, with Google and Anthropic expected to respond with their own next-generation models in the coming months.',
  ),
  Article(
    id: 'seed-2',
    source: 'The Verge',
    title: 'Apple Announces M5 Ultra Chip With 128-Core GPU for Mac Pro',
    url: 'https://example.com/m5-ultra',
    author: 'James Rivera',
    publishedAt: null,
    macroTag: 'Hardware',
    macroTags: ['Hardware', 'Tech'],
    microTags: ['Apple', 'M5', 'Mac Pro', 'GPU', 'Chip'],
    tldr:
        'Apple revealed the M5 Ultra chip at its fall event, featuring a 128-core GPU and 48-core CPU. The chip targets professional creative workloads and is expected to ship in the new Mac Pro by early next year.',
    cleanText:
        'At its fall hardware event, Apple unveiled the M5 Ultra — the most powerful chip in its silicon lineup. Built on TSMC\'s 2nm process, the M5 Ultra packs a 48-core CPU, 128-core GPU, and a 64-core Neural Engine.\n\nThe chip supports up to 512 GB of unified memory with 800 GB/s bandwidth, making it a compelling option for 8K video editing, 3D rendering, and large-scale machine learning training.\n\nApple demonstrated the chip running a complex Blender scene render that completed in under 3 minutes — a task that took over 20 minutes on the previous M4 Ultra. The company also showed real-time ray tracing in professional CAD applications.\n\nThe new Mac Pro featuring the M5 Ultra is expected to ship in Q1 next year, with pricing starting at \$6,999.',
  ),
  Article(
    id: 'seed-3',
    source: 'Ars Technica',
    title: 'Quantum Computing Milestone: IBM Achieves 10,000-Qubit Processor',
    url: 'https://example.com/ibm-quantum',
    author: 'Dr. Lisa Park',
    publishedAt: null,
    macroTag: 'Science',
    macroTags: ['Science', 'Tech'],
    microTags: ['IBM', 'Quantum Computing', 'Qubit', 'Processor'],
    tldr:
        'IBM has reached a major milestone with its 10,000-qubit quantum processor, codenamed Condor-X. The processor demonstrates error rates low enough for practical quantum advantage in materials science simulations.',
    cleanText:
        'IBM has unveiled Condor-X, the world\'s first 10,000-qubit quantum processor, marking a significant step toward practical quantum computing. The processor uses IBM\'s latest error-correction techniques to achieve coherence times that enable meaningful computations.\n\nThe breakthrough lies not just in qubit count but in error rates. IBM reports a 99.9% two-qubit gate fidelity, making it possible to run algorithms with enough depth to outperform classical supercomputers on specific materials science problems.\n\nIn a demonstration, the processor simulated the behavior of a novel lithium-ion battery cathode material in 4 hours — a calculation that would take the world\'s fastest classical supercomputer an estimated 47 years.\n\nIBM plans to make Condor-X available through its Quantum Network to select research partners by mid-next year, with broader cloud access following in 2027.',
  ),
  Article(
    id: 'seed-4',
    source: 'Wired',
    title: 'Tesla Robotaxi Fleet Launches in San Francisco With 1,000 Vehicles',
    url: 'https://example.com/tesla-robotaxi',
    author: 'Michael Torres',
    publishedAt: null,
    macroTag: 'Automotive',
    macroTags: ['Automotive', 'Tech', 'AI'],
    microTags: ['Tesla', 'Robotaxi', 'Self-Driving', 'San Francisco'],
    tldr:
        'Tesla has officially launched its robotaxi service in San Francisco with a fleet of 1,000 purpose-built vehicles. The service operates 24/7 in designated zones and uses Tesla\'s FSD v14 system without safety drivers.',
    cleanText:
        'Tesla\'s long-awaited robotaxi service has gone live in San Francisco, deploying 1,000 purpose-built vehicles across the city. The service, branded as "Tesla Go," operates around the clock within a geofenced area covering most of the city\'s core neighborhoods.\n\nThe vehicles run Tesla\'s Full Self-Driving version 14, which the company says has achieved a safety record of over 10 million miles without a reportable incident during its testing phase. Unlike earlier autonomous taxi services, Tesla\'s vehicles have no steering wheel or pedals.\n\nRides are priced at roughly 60% of traditional rideshare costs, with a base fare of \$3 plus \$1.20 per mile. Tesla plans to expand to Los Angeles and Austin within three months.\n\nThe launch has reignited debate about autonomous vehicle regulation, with the California DMV announcing new oversight requirements for fleets exceeding 500 vehicles.',
  ),
  Article(
    id: 'seed-5',
    source: 'GameSpot',
    title:
        'Nintendo Switch 3 Reveal: 4K Gaming, Backward Compatibility Confirmed',
    url: 'https://example.com/switch3',
    author: 'Emily Nakamura',
    publishedAt: null,
    macroTag: 'Gaming',
    macroTags: ['Gaming', 'Tech', 'Hardware'],
    microTags: ['Nintendo', 'Switch 3', '4K', 'Console'],
    tldr:
        'Nintendo has officially revealed the Switch 3, featuring 4K output when docked, an OLED display for handheld mode, and full backward compatibility with all Switch and Switch 2 titles. Launch is set for March next year.',
    cleanText:
        'Nintendo has pulled back the curtain on the Switch 3, the next generation of its hybrid console. The device features a custom NVIDIA chip capable of 4K output when docked, while its 7.9-inch OLED display runs games at 1080p in handheld mode.\n\nFull backward compatibility with Switch and Switch 2 physical and digital titles was confirmed, along with a new "Enhanced Mode" that automatically upscales older games with improved frame rates and resolution.\n\nThe Switch 3 introduces haptic feedback triggers, a wider kickstand, and 6 hours of battery life for demanding games. Online services will carry over from existing Nintendo accounts.\n\nLaunch titles include a new 3D Mario adventure, Metroid Prime 4 Remastered, and a surprise Zelda announcement. The console is priced at \$399 and launches in March.',
  ),
  Article(
    id: 'seed-6',
    source: 'Bloomberg',
    title: 'Global Chip Shortage Finally Easing as TSMC Expands 2nm Production',
    url: 'https://example.com/tsmc-2nm',
    author: 'David Wu',
    publishedAt: null,
    macroTag: 'Tech',
    macroTags: ['Tech', 'Hardware', 'Finance'],
    microTags: ['TSMC', 'Semiconductor', '2nm', 'Supply Chain'],
    tldr:
        'TSMC has begun mass production on its 2nm process node, with new fabs in Taiwan and Arizona reaching full capacity. Analysts say the global chip shortage that began in 2020 is now effectively over for most sectors.',
    cleanText:
        'Taiwan Semiconductor Manufacturing Company (TSMC) has announced that its 2nm process node has entered mass production at facilities in both Tainan, Taiwan and Chandler, Arizona. The expansion marks a turning point in the global semiconductor supply chain.\n\nThe 2nm node offers a 25% performance improvement and 30% power reduction compared to the previous 3nm generation. Major customers including Apple, NVIDIA, AMD, and Qualcomm have already placed orders.\n\nTSMC\'s Arizona fab — its first major US manufacturing facility — is now producing chips at 90% yield rates, addressing concerns about the viability of advanced chipmaking outside Asia.\n\nIndustry analysts from Gartner and IDC agree that the persistent chip shortages that disrupted global supply chains since 2020 are now effectively resolved, with semiconductor inventory levels returning to pre-pandemic norms across automotive, consumer electronics, and industrial sectors.',
  ),
  Article(
    id: 'seed-7',
    source: 'MIT Technology Review',
    title: 'CRISPR Gene Therapy Cures Sickle Cell Disease in 500-Patient Trial',
    url: 'https://example.com/crispr-sickle',
    author: 'Dr. Amanda Foster',
    publishedAt: null,
    macroTag: 'Science',
    macroTags: ['Science', 'Tech'],
    microTags: ['CRISPR', 'Gene Therapy', 'Sickle Cell', 'Biotech'],
    tldr:
        'A landmark clinical trial has shown that a one-time CRISPR-based gene therapy effectively cures sickle cell disease, with 98% of 500 patients remaining symptom-free after two years. FDA approval is expected within months.',
    cleanText:
        'Results from the largest CRISPR gene therapy trial to date show a 98% success rate in curing sickle cell disease. The Phase 3 trial, conducted across 30 medical centers in the US and Europe, treated 500 patients with a single infusion of edited stem cells.\n\nThe therapy, developed by Vertex Pharmaceuticals and CRISPR Therapeutics, works by editing the BCL11A gene in patients\' own blood stem cells, reactivating fetal hemoglobin production. After two years of follow-up, 490 of 500 patients have had zero vaso-occlusive crises.\n\nThe treatment currently costs approximately \$2.2 million per patient, though the companies have proposed outcomes-based pricing models that would tie payment to long-term efficacy.\n\nThe FDA is expected to grant full approval within the next six months, following the therapy\'s existing conditional approval for a smaller patient population.',
  ),
  Article(
    id: 'seed-8',
    source: 'TechCrunch',
    title:
        'SpaceX Starlink V3 Satellites Promise 1Gbps Direct-to-Phone Internet',
    url: 'https://example.com/starlink-v3',
    author: 'Rachel Kim',
    publishedAt: null,
    macroTag: 'Tech',
    macroTags: ['Tech', 'Hardware'],
    microTags: ['SpaceX', 'Starlink', 'Satellite', 'Internet'],
    tldr:
        'SpaceX has begun deploying its third-generation Starlink satellites, promising gigabit speeds for fixed terminals and up to 100 Mbps for direct-to-smartphone connections without any special hardware.',
    cleanText:
        'SpaceX has started launching its Starlink V3 satellite constellation, a major upgrade that promises to bring high-speed internet to every corner of the planet. The new satellites are three times heavier than their predecessors and carry significantly more powerful antennas.\n\nFor fixed-dish customers, V3 promises speeds up to 1 Gbps with latency under 20ms — competitive with fiber optic connections. More notably, the satellites support direct-to-phone connectivity at speeds up to 100 Mbps, working with standard smartphones without any hardware modifications.\n\nSpaceX has signed carrier agreements with T-Mobile, Vodafone, and KDDI to offer the direct-to-phone service, which will initially provide coverage in areas without terrestrial cell towers.\n\nThe full V3 constellation of 7,500 satellites is expected to be operational by late next year, complementing the existing 6,000+ V2 satellites already in orbit.',
  ),
  Article(
    id: 'seed-9',
    source: 'The Verge',
    title: 'Microsoft Copilot Gets Full OS Integration in Windows 12 Preview',
    url: 'https://example.com/windows12-copilot',
    author: 'Alex Johnson',
    publishedAt: null,
    macroTag: 'AI',
    macroTags: ['AI', 'Tech'],
    microTags: ['Microsoft', 'Copilot', 'Windows 12', 'AI Assistant'],
    tldr:
        'The first Windows 12 preview build features deep Copilot AI integration across the OS — from file management and settings to cross-app workflows. Microsoft calls it the first "AI-native" operating system.',
    cleanText:
        'Microsoft has released the first Insider Preview of Windows 12, and the headline feature is pervasive AI integration through Copilot. Unlike Windows 11\'s sidebar approach, Copilot in Windows 12 is woven into every layer of the operating system.\n\nUsers can ask Copilot to find and organize files, adjust system settings, create automated workflows across applications, and even debug code directly from the desktop. The AI maintains context across sessions and learns user preferences over time.\n\nA new "Copilot Actions" feature lets users chain together multi-step tasks. For example, saying "prepare my morning briefing" can open email, summarize unread messages, check calendar events, and compile a to-do list — all in one command.\n\nThe preview also introduces a redesigned Start menu, native Android app support without emulation, and a new security model that sandboxes all third-party applications by default. Windows 12 is expected to launch in the second half of next year.',
  ),
  Article(
    id: 'seed-10',
    source: 'Ars Technica',
    title: 'EU Passes Landmark AI Regulation: What It Means for Tech Companies',
    url: 'https://example.com/eu-ai-act',
    author: 'Maria Gonzalez',
    publishedAt: null,
    macroTag: 'Tech',
    macroTags: ['Tech', 'AI'],
    microTags: ['EU', 'Regulation', 'AI Act', 'Policy', 'Compliance'],
    tldr:
        'The European Union has enacted comprehensive AI regulations requiring transparency reports, bias audits, and human oversight for high-risk AI systems. Companies face fines up to 7% of global revenue for non-compliance.',
    cleanText:
        'The European Union\'s AI Act has officially entered into force, establishing the world\'s most comprehensive regulatory framework for artificial intelligence. The legislation categorizes AI systems by risk level and imposes strict requirements on those deemed "high-risk."\n\nHigh-risk AI systems — including those used in hiring, credit scoring, law enforcement, and healthcare — must undergo regular bias audits, maintain detailed transparency reports, and implement human oversight mechanisms.\n\nGeneral-purpose AI models like large language models face separate obligations, including disclosing training data sources, publishing technical documentation, and implementing safeguards against generating illegal content.\n\nNon-compliance carries severe penalties: up to 7% of a company\'s global annual revenue, surpassing the GDPR\'s 4% maximum. Major tech companies including Google, Meta, Microsoft, and OpenAI have announced dedicated compliance teams.\n\nThe regulation takes full effect in 18 months, with a 6-month grace period for general-purpose AI provisions. Industry groups estimate compliance costs could reach \$10 billion globally across the tech sector.',
  ),
];
