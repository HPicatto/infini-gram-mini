"""infini-gram mini: exact n-gram search over an FM-index.

Installed layout keeps the Python modules and the two indexing binaries in one
directory, because indexing.py chdirs to its own location and invokes
./cpp_indexing and ./rust_indexing from there.

    from infini_gram_mini import InfiniGramMiniEngine
    engine = InfiniGramMiniEngine(index_dirs=["/abs/index"],
                                  load_to_ram=False, get_metadata=True)
    engine.count("natural language processing")
"""

from .engine import InfiniGramMiniEngine

__all__ = ["InfiniGramMiniEngine"]
