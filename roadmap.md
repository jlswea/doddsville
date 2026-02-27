# Roadmap

- Add tagesschau scraper to new sensors package
- Add justETF scraper to sensors package (for ETFs but also all stocks list)
- Add shiller PE as sensor
- Validate Date in paperless metadata
- Strategy for choosing an unique title in paperless metadata
- Add persers for importing transactions to speed up import. 
    They should be loaded based on `dv import` arguments or guessed based on PDF content. 
    As a Fallback all available parser could be tried until one matches.
    If no one matches, use ollama
- Skip OCR on paperless server when uploaded from dv
