from tokenizers import BertWordPieceTokenizer
import sys, json

def main():
    try:
        tokenizer = BertWordPieceTokenizer("vocab.txt")
        text = sys.stdin.read().strip()
        if not text:
            print("[]")
            return
        encoding = tokenizer.encode(text)
        print(json.dumps(encoding.ids))
    except Exception as e:
        print("❌ Tokenizer error:", e)

if __name__ == "__main__":
    main()
