# MT5 Optimization Analyzer

Локальный инструмент для анализа больших XML-отчетов оптимизации MetaTrader 5.

## Что делает

- Потоково читает Spreadsheet XML от MT5.
- Строит агрегаты по параметрам оптимизации.
- Показывает графики, топ проходов и лучшие диапазоны параметров.
- Кэширует результат, чтобы не пересчитывать большой XML каждый раз.

## Структура

- `app.py` - локальный HTTP server и backend-аналитика
- `index.html` - интерфейс
- `data/` - папка для XML-файлов
- `cache/` - автоматически создаваемый кэш, в git не хранится

## Запуск

```powershell
cd "C:\Users\Max\AppData\Roaming\MetaQuotes\Terminal\55377913BF8510B9774D8928583AA295\MQL5\Tools\MT5OptimizationAnalyzer"
python .\app.py
```

Открыть в браузере:

```text
http://127.0.0.1:8765/
```
